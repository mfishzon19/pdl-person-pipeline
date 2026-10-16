"""PDL Company enrichment pipeline — `/v5/company/enrich/bulk` (bulk, billed).

`CompanyEnrichmentCaller` is a `BulkPDLCaller` (sibling of `PDLCaller`, no shared
inheritance — see `docs/design/18_pdl_api_generic_caller.md` v0.3).
It overrides the two response-shape hooks (`build_bulk_payload`,
`map_bulk_response`) plus the queue-specific data-access hooks that encode
`company_input_list` specifics a generic bulk base can't know: source-list
scoping on the claim, the `company_enrichment_batch_seq` grouping id, the
`pdl_company_id` sibling-skip, and the replay-from-audit stale reclaim. The
bulk ORCHESTRATION (claim → call → record → finalize ordering, credit-cap and
pacing) lives in `BulkPDLCaller.process_batch`.

The company-specific SQL lives in the module-level functions below (unit-tested
directly); the class hooks are thin adapters onto them.

Schema: `V3__pdl_api_company_enrichment.sql` (queue `pdl_api.company_input_list`,
views `v_company_input_for_cleaner` / `v_company_input_for_enrichment`, audit
`pdl_api.company_cleaner_call` / `pdl_api.company_enrichment_call`).

Reads the PDL API key from `PDL_API_KEY`. `DATABASE_URL` (or libpq PG* vars)
drives the connection. `python -m processing.pdl_api.company_enrichment run
--source-list X --max-credits N` enriches pending rows (`make enrich-pdl`);
with no arguments it runs a live end-to-end demo (guarded by
`PDL_DEMO_CONFIRM=1`).
"""

from __future__ import annotations

import json
import os
import socket
import sys
import time

import psycopg2.extras

from processing.common.db import connect
from processing.pdl_api.base import (
    DEFAULT_CREDIT_CAP_PER_MONTH,
    DEFAULT_MAX_ATTEMPTS,
    DEFAULT_STALE_MINUTES,
    BulkPDLCaller,
    RateLimiter,
)
from processing.pdl_api.base import (
    MAX_BULK_RECORDS as _MAX_BULK_RECORDS,
)

# The cleaner pass lives in company_cleaner.py; re-export its public API so both
# passes (and the demo below) are reachable from this module.
from processing.pdl_api.company_cleaner import (  # noqa: F401
    DEFAULT_CLEANER_RPM,
    CompanyCleanerCaller,
    process_cleaner_batch,
)

# Default bulk-enrich rate limit. Caller overrides with the plan's value.
DEFAULT_BULK_ENRICH_RPM = 10


# -----------------------------------------------------------------------------
# CompanyEnrichmentCaller — bulk subclass of BulkPDLCaller
# -----------------------------------------------------------------------------

class CompanyEnrichmentCaller(BulkPDLCaller):
    """`/v5/company/enrich/bulk`. Up to 100 rows per HTTP call; per-record
    results reconciled by `metadata.input_list_id`."""

    def __init__(self, *, rate_limit_rpm=DEFAULT_BULK_ENRICH_RPM,
                 credit_cap_per_day=None,
                 credit_cap_per_month=DEFAULT_CREDIT_CAP_PER_MONTH):
        super().__init__(
            endpoint_url="/v5/company/enrich/bulk",
            driver_view="pdl_api.v_company_input_for_enrichment",
            queue_table="pdl_api.company_input_list",
            queue_status_column="enrichment_status",
            audit_table="pdl_api.company_enrichment_call",
            rate_limit_rpm=rate_limit_rpm,
            credit_cap_per_day=credit_cap_per_day,
            credit_cap_per_month=credit_cap_per_month,
        )

    # --- response-shape hooks --- #

    def build_bulk_payload(self, claimed_rows):
        """One bulk request body. `passthrough_params` is echoed via PDL's
        per-record metadata alongside the correlation `input_list_id`."""
        return {
            "requests": [
                {
                    "params": {"pdl_id": row["pdl_company_id"]},
                    "metadata": {
                        "input_list_id": row["id"],
                        **(row.get("passthrough_params") or {}),
                    },
                }
                for row in claimed_rows
            ],
        }

    def map_bulk_response(self, result, claimed_rows):
        """Reconcile each per-record response slot back to its queue row by
        `metadata.input_list_id` (never by order — PDL may reorder). Returns
        [(input_list_id, terminal_status, extras)]. 200 -> enriched, 404 ->
        not_found, anything else (incl. a dropped / 1 MB-truncated slot) ->
        error, so it is retried, never a false success."""
        by_input_id = _index_response(result)
        records = []
        for row in claimed_rows:
            item = by_input_id.get(row["id"])
            status = item.get("status") if isinstance(item, dict) else None
            if status == 200 and isinstance(item, dict):
                new_status = "enriched"
            elif status == 404:
                new_status = "not_found"
            else:
                new_status = "error"
            records.append((row["id"], new_status, {}))
        return records

    # --- queue-specific data-access hooks --- #

    def _claim(self, conn, worker_id, limit, source_list):
        return _claim_enrichment_rows(conn, worker_id, limit, source_list=source_list)

    def _next_batch_id(self, conn):
        return _next_bulk_batch_id(conn)

    def _record_batch(self, conn, batch_id, claimed, result):
        _record_enrichment_calls_bulk(conn, batch_id, claimed,
                                      _index_response(result), result)

    def _skip_siblings(self, conn, batch_id):
        _mark_sibling_skips(conn, batch_id)

    def reclaim_stale(self, conn, stale_minutes=DEFAULT_STALE_MINUTES, source_list=None):
        return reclaim_stale_enrichment(conn, stale_minutes, source_list)

    def requeue_retryable(self, conn, max_attempts=DEFAULT_MAX_ATTEMPTS, source_list=None):
        return requeue_retryable_errors(conn, source_list, max_attempts)


# -----------------------------------------------------------------------------
# Module-level bulk SQL (the class hooks + run_enrichment share these)
# -----------------------------------------------------------------------------

def process_enrichment_batch(conn, worker_id, limit=_MAX_BULK_RECORDS, *, source_list=None):
    """Function-style wrapper used by run_enrichment and the demo. Delegates to
    `CompanyEnrichmentCaller.process_batch`, which owns the bulk orchestration.
    Returns the number of rows processed."""
    return CompanyEnrichmentCaller().process_batch(
        conn, worker_id, limit=limit, source_list=source_list)


def _index_response(result):
    """Index a bulk response's per-record slots by metadata.input_list_id."""
    items = result["body"] if isinstance(result.get("body"), list) else []
    by_input_id = {}
    for item in items:
        if isinstance(item, dict):
            md = item.get("metadata") or {}
            input_id = md.get("input_list_id")
            if input_id is not None:
                by_input_id[input_id] = item
    return by_input_id


def _claim_enrichment_rows(conn, worker_id, limit, source_list=None):
    """Reserve pending enrichment rows. source_list=None runs through
    v_company_input_for_enrichment (global); a source_list scopes to that list,
    mirroring the view's predicate so a bounded run can't pick up unrelated
    pending rows."""
    if source_list is None:
        picked_sql = """
            SELECT input_list_id
            FROM   pdl_api.v_company_input_for_enrichment
            ORDER BY input_list_id
            FOR UPDATE SKIP LOCKED
            LIMIT %(limit)s
        """
    else:
        picked_sql = """
            SELECT id AS input_list_id
            FROM   pdl_api.company_input_list
            WHERE  enrichment_status = 'pending'
              AND  pdl_company_id IS NOT NULL
              AND  source_list = %(source_list)s
            ORDER BY id
            FOR UPDATE SKIP LOCKED
            LIMIT %(limit)s
        """
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            f"""
            WITH picked AS ({picked_sql})
            UPDATE pdl_api.company_input_list cil
            SET    enrichment_status = 'in_progress',
                   worker_id         = %(worker_id)s,
                   claimed_at        = clock_timestamp()
            FROM   picked
            WHERE  cil.id = picked.input_list_id
            RETURNING cil.id, cil.pdl_company_id, cil.passthrough_params
            """,
            {"limit": limit, "worker_id": worker_id, "source_list": source_list},
        )
        rows = cur.fetchall()
    conn.commit()
    return rows


def _next_bulk_batch_id(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT nextval('pdl_api.company_enrichment_batch_seq')")
        return cur.fetchone()[0]


def _resolve_item(item, bulk_result):
    """Map a per-record response slot to (status, response_json, error_message).
    Missing item (dropped / 1 MB-truncated) -> NULL status + NULL body so it
    reads as 'no data' downstream (retryable), never as a false success."""
    if isinstance(item, dict) and "status" in item:
        err = item.get("error")
        return (item.get("status"), item,
                err.get("message") if isinstance(err, dict) else None)
    return (None, None,
            bulk_result["error_message"] or "no per-record response from bulk endpoint")


def _record_enrichment_calls_bulk(conn, bulk_batch_id, claimed, by_input_id, bulk_result):
    """Insert all per-record audit rows for one bulk call in a single
    transaction. Persisting the whole response atomically — before the queue
    is finalized — is what lets recovery replay instead of re-calling PDL."""
    values = []
    for row in claimed:
        status, response_json, error_message = _resolve_item(
            by_input_id.get(row["id"]), bulk_result)
        values.append((
            bulk_batch_id, row["id"], "/v5/company/enrich/bulk",
            json.dumps({"params": {"pdl_id": row["pdl_company_id"]},
                        "metadata": {"input_list_id": row["id"]}}),
            status,
            json.dumps(response_json) if response_json is not None else None,
            bulk_result["latency_ms"], error_message,
        ))
    with conn.cursor() as cur:
        psycopg2.extras.execute_values(
            cur,
            """INSERT INTO pdl_api.company_enrichment_call
               (bulk_batch_id, input_list_id, endpoint, request_json,
                response_status, response_json, latency_ms, error_message)
               VALUES %s""",
            values,
            template="(%s,%s,%s,%s::jsonb,%s,%s::jsonb,%s,%s)",
        )
    conn.commit()


def _mark_sibling_skips(conn, bulk_batch_id):
    """If the same pdl_company_id is on multiple queue rows (e.g. the same company
    appears on two source lists), flip the other unfinished ones to skipped_already_enriched once
    we've enriched one of them in this batch.

    Covers both 'pending' AND 'in_progress' siblings: an in_progress
    sibling being worked by a concurrent worker on a different source_list would
    otherwise be sent to PDL a second time and billed twice for one company. The
    guarded finalize (base._record_and_finalize / _finalize_batch) then makes the
    losing worker's write a no-op, so the skip is safe even mid-flight."""
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE pdl_api.company_input_list
            SET    enrichment_status = 'skipped_already_enriched',
                   worker_id = NULL, claimed_at = NULL
            WHERE  enrichment_status IN ('pending', 'in_progress')
              AND  pdl_company_id IN (
                    SELECT pdl_company_id
                    FROM   pdl_api.company_enrichment_call
                    WHERE  bulk_batch_id = %s AND response_status = 200
                   )
            """,
            (bulk_batch_id,),
        )
    conn.commit()


# -----------------------------------------------------------------------------
# Safeguards: credit cap, auto-retry, replay-based stale reclaim
# -----------------------------------------------------------------------------

def _credits_spent(conn, source_list=None):
    """Count successful enrichments — one PDL credit each (PDL bills per
    successful record). Scope to a source_list for a bounded run. This is
    the per-RUN budget counter used by run_enrichment; the class-level
    credit_cap_per_day / _per_month use the calendar-scoped counters in base."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT count(*)
            FROM   pdl_api.company_enrichment_call ec
            JOIN   pdl_api.company_input_list c ON c.id = ec.input_list_id
            WHERE  ec.response_status = 200
              AND  (%(sl)s IS NULL OR c.source_list = %(sl)s)
            """,
            {"sl": source_list},
        )
        return cur.fetchone()[0]


def requeue_retryable_errors(conn, source_list=None, max_attempts=DEFAULT_MAX_ATTEMPTS):
    """Flip rows stuck in enrichment_status='error' back to 'pending' for another
    PDL call, bounded to max_attempts per company. Covers exhausted HTTP retries
    and rows dropped from a truncated (1 MB) bulk response. 404/'not_found' stays
    terminal. Returns the number requeued."""
    with conn.cursor() as cur:
        cur.execute(
            """
            WITH attempts AS (
                SELECT input_list_id, count(*) AS n
                FROM   pdl_api.company_enrichment_call
                GROUP  BY input_list_id
            )
            UPDATE pdl_api.company_input_list c
            SET    enrichment_status = 'pending',
                   worker_id         = NULL,
                   claimed_at        = NULL
            FROM   attempts a
            WHERE  c.id = a.input_list_id
              AND  c.enrichment_status = 'error'
              AND  a.n < %(max_attempts)s
              AND  (%(sl)s IS NULL OR c.source_list = %(sl)s)
            """,
            {"max_attempts": max_attempts, "sl": source_list},
        )
        n = cur.rowcount
    conn.commit()
    return n


def reclaim_stale_enrichment(conn, stale_minutes=DEFAULT_STALE_MINUTES, source_list=None):
    """Recover rows stuck 'in_progress' from a crashed worker, double-spend safe.
    Because process_batch persists the whole response BEFORE finalizing the
    queue, a stuck row whose audit row exists is *replayed* from that saved
    response (no new PDL call, no re-charge). Only rows with NO audit row go back
    to 'pending'. `stale_minutes` is clamped to >= 1 so a fractional value can't
    floor to 0 and reclaim rows still being processed. Returns (replayed, requeued)."""
    minutes = max(1, int(stale_minutes))
    interval = f"{minutes} minutes"
    with conn.cursor() as cur:
        cur.execute(
            """
            WITH latest AS (
                SELECT DISTINCT ON (ec.input_list_id)
                       ec.input_list_id,
                       ec.response_status,
                       (ec.response_json IS NOT NULL) AS has_body
                FROM   pdl_api.company_enrichment_call ec
                ORDER  BY ec.input_list_id, ec.called_at DESC, ec.id DESC
            )
            UPDATE pdl_api.company_input_list c
            SET    enrichment_status = CASE
                       WHEN l.response_status = 200 AND l.has_body THEN 'enriched'
                       WHEN l.response_status = 404               THEN 'not_found'
                       ELSE 'error' END,
                   worker_id = NULL, claimed_at = NULL
            FROM   latest l
            WHERE  c.id = l.input_list_id
              AND  c.enrichment_status = 'in_progress'
              AND  c.claimed_at < now() - %(interval)s::interval
              AND  (%(sl)s IS NULL OR c.source_list = %(sl)s)
            """,
            {"interval": interval, "sl": source_list},
        )
        replayed = cur.rowcount
        cur.execute(
            """
            UPDATE pdl_api.company_input_list c
            SET    enrichment_status = 'pending', worker_id = NULL, claimed_at = NULL
            WHERE  c.enrichment_status = 'in_progress'
              AND  c.claimed_at < now() - %(interval)s::interval
              AND  (%(sl)s IS NULL OR c.source_list = %(sl)s)
              AND  NOT EXISTS (SELECT 1 FROM pdl_api.company_enrichment_call ec
                               WHERE ec.input_list_id = c.id)
            """,
            {"interval": interval, "sl": source_list},
        )
        requeued = cur.rowcount
    conn.commit()
    return replayed, requeued


def run_enrichment(conn, worker_id, source_list, *, max_credits,
                   batch_size=_MAX_BULK_RECORDS,
                   requests_per_minute=DEFAULT_BULK_ENRICH_RPM,
                   max_attempts=DEFAULT_MAX_ATTEMPTS,
                   stale_minutes=DEFAULT_STALE_MINUTES,
                   sleep_fn=time.sleep, log_fn=print):
    """Drive the enrichment pass for one source_list with all safeguards on:

      - credit cap: stop once max_credits successful enrichments are reached;
        each batch is clamped so it can't overshoot. None disables (not
        recommended for a paid run).
      - rate limit: at most requests_per_minute bulk calls per minute (one
        RateLimiter shared across the whole run).
      - auto-retry: errored / truncated rows retried up to max_attempts; stale
        in_progress rows reclaimed (replay-safe) first.

    Returns total rows processed. One RateLimiter for the whole run so pacing
    persists across batches.
    """
    if batch_size > _MAX_BULK_RECORDS:
        raise ValueError(
            f"batch_size={batch_size} exceeds PDL bulk cap ({_MAX_BULK_RECORDS}).")

    limiter = RateLimiter(requests_per_minute, sleep_fn=sleep_fn)

    replayed, req = reclaim_stale_enrichment(conn, stale_minutes, source_list)
    if replayed or req:
        log_fn(f"[reclaim] replayed {replayed} from saved response, "
               f"requeued {req} unsaved stale in_progress")

    total = 0
    while True:
        spent = _credits_spent(conn, source_list)
        if max_credits is not None and spent >= max_credits:
            log_fn(f"[cap] credit cap reached ({spent}/{max_credits}); stopping")
            break

        this_batch = batch_size
        if max_credits is not None:
            this_batch = min(batch_size, max_credits - spent)
        if this_batch <= 0:
            break

        limiter.wait()
        n = process_enrichment_batch(conn, worker_id, limit=this_batch,
                                     source_list=source_list)

        if n == 0:
            rq = requeue_retryable_errors(conn, source_list, max_attempts)
            if rq:
                log_fn(f"[retry] requeued {rq} retryable error row(s)")
                continue
            break

        total += n
        log_fn(f"[batch] processed {n}  "
               f"(credits {_credits_spent(conn, source_list)}/{max_credits})")

    return total


# -----------------------------------------------------------------------------
# Demo entry point
# -----------------------------------------------------------------------------

def _demo():
    """Seed two queue rows, run both passes, dump the resulting state.

    The seed values are placeholders: replace them with a company name and a
    `pdl_company_id` you want to look up. Placeholder ids come back as
    `not_found`, which still exercises the full claim/call/record/finalize path."""
    worker_id = f"demo@{socket.gethostname()}"

    conn = connect()
    try:
        with conn.cursor() as cur:
            # Clean slate for a deterministic demo. Scoped to demo_list so
            # the run is safe against a shared dev DB that already holds
            # real queue / audit data.
            cur.execute(
                "DELETE FROM pdl_api.company_enrichment_call "
                "WHERE input_list_id IN ("
                "  SELECT id FROM pdl_api.company_input_list "
                "  WHERE source_list = 'demo_list'"
                ")"
            )
            cur.execute(
                "DELETE FROM pdl_api.company_cleaner_call "
                "WHERE input_list_id IN ("
                "  SELECT id FROM pdl_api.company_input_list "
                "  WHERE source_list = 'demo_list'"
                ")"
            )
            cur.execute(
                "DELETE FROM pdl_api.company_input_list "
                "WHERE source_list = 'demo_list'"
            )

            cur.execute("""
                INSERT INTO pdl_api.company_input_list (
                    source_list, pdl_search_params, pdl_company_id,
                    cleaner_status, enrichment_status
                ) VALUES
                ('demo_list', '{"name": "Acme Corp"}'::jsonb, NULL,
                 'pending', 'pending'),
                ('demo_list', '{"id": "example-pdl-company-id"}'::jsonb,
                 'example-pdl-company-id', 'not_needed', 'pending')
            """)
        conn.commit()

        print("=== seeded company_input_list ===")
        _print_queue(conn)

        print("\n=== running cleaner pass ===")
        n = process_cleaner_batch(conn, worker_id)
        print(f"  processed {n} row(s)")
        _print_queue(conn)

        print("\n=== running enrichment pass ===")
        n = process_enrichment_batch(conn, worker_id)
        print(f"  processed {n} row(s)")
        _print_queue(conn)

        print("\n=== pdl_api.company_cleaner_call ===")
        _print_table(conn, "pdl_api.company_cleaner_call",
                     ["id", "input_list_id", "response_status",
                      "pdl_company_id", "latency_ms"])

        print("\n=== pdl_api.company_enrichment_call ===")
        _print_table(conn, "pdl_api.company_enrichment_call",
                     ["id", "bulk_batch_id", "input_list_id", "response_status",
                      "pdl_company_id", "pdl_dataset_version", "pdl_likelihood"])
    finally:
        conn.close()


def _print_queue(conn):
    _print_table(conn, "pdl_api.company_input_list",
                 ["id", "source_list", "pdl_company_id",
                  "cleaner_status", "enrichment_status"])


def _print_table(conn, table, columns):
    with conn.cursor() as cur:
        cur.execute(f"SELECT {', '.join(columns)} FROM {table} ORDER BY 1")
        rows = cur.fetchall()
    if not rows:
        print("  (empty)")
        return
    widths = [max(len(str(r[i])) for r in rows + [tuple(columns)])
              for i in range(len(columns))]
    print("  " + "  ".join(c.ljust(w) for c, w in zip(columns, widths, strict=True)))
    print("  " + "  ".join("-" * w for w in widths))
    for r in rows:
        print("  " + "  ".join(str(v).ljust(w) for v, w in zip(r, widths, strict=True)))


def _run_cli(argv):
    """`run --source-list X --max-credits N [--rpm N]`: enrich pending queue rows
    for one source_list via run_enrichment(), with all safeguards on. The credit
    cap is required so a paid run can never be unbounded."""
    import argparse
    p = argparse.ArgumentParser(prog="python -m processing.pdl_api.company_enrichment")
    p.add_argument("command", choices=["run"])
    p.add_argument("--source-list", required=True,
                   help="company_input_list.source_list to enrich")
    p.add_argument("--max-credits", type=int, required=True,
                   help="stop after this many successful (billed) enrichments")
    p.add_argument("--rpm", type=int, default=DEFAULT_BULK_ENRICH_RPM,
                   help="bulk requests/min pacing (default %(default)s)")
    args = p.parse_args(argv)
    conn = connect()
    try:
        n = run_enrichment(conn, f"company_enrichment@{socket.gethostname()}",
                           args.source_list, max_credits=args.max_credits,
                           requests_per_minute=args.rpm)
        print(f"enriched {n} company rows")
    finally:
        conn.close()


if __name__ == "__main__":
    if sys.argv[1:2] == ["run"]:
        _run_cli(sys.argv[1:])
        sys.exit(0)
    # Guard: _demo() calls the real PDL API (billable) using PDL_API_KEY.
    # Require explicit opt-in so a dev env that happens to have PDL_API_KEY
    # set can't trigger live calls by running this module.
    if os.environ.get("PDL_DEMO_CONFIRM") != "1":
        sys.exit(
            "Refusing to run the live PDL demo without confirmation. "
            "It calls the real PDL API (billable) using PDL_API_KEY. "
            "Re-run with PDL_DEMO_CONFIRM=1 to proceed."
        )
    _demo()
