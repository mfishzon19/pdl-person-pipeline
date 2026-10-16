"""Generic PDL API caller framework.

Two **sibling** base classes — one per HTTP pattern — that do NOT share an
inheritance chain. They share plumbing through module-level helper functions in
this file (rate limiter, credit-cap checks, pending count, stale reclaim, retry
requeue). See `docs/design/18_pdl_api_generic_caller.md`.

  - `PDLCaller`      — single-record cleaners (`/v5/company/clean`,
                       `/v5/location/clean`, `/v5/school/clean`). One HTTP call
                       per claimed queue row. Subclass overrides `build_payload`
                       + `map_status`.
  - `BulkPDLCaller`  — bulk enrichment (`/v5/company/enrich/bulk`). One HTTP call
                       carries up to `max_batch_size` rows; per-record results
                       reconciled via `metadata.input_list_id`. Subclass overrides
                       `build_bulk_payload` + `map_bulk_response` (plus the small
                       data-access hooks a bulk queue needs).

Why two classes rather than one hierarchy: the single-record and bulk shapes
differ in what a "batch" is, how responses reconcile, how `reclaim_stale`
interacts with billing (cheap-retry vs. replay-from-audit to avoid
double-charging), and what `process_batch` naturally accepts. An earlier
revision forced both into one hierarchy and the bulk subclass had to override
every public method to delegate elsewhere — a facade that produced LSP
violations (mismatched signatures + return types) and silently-ignored
constructor params. Siblings eliminate that by construction.

Rate limits are enforced globally by the HTTP wrapper in `processing/common/pdl`
(429 / Retry-After handling). `rate_limit_rpm` here is intra-worker pacing.

Table / view / column names passed to a constructor are trusted identifiers
(they come from subclass code, never user input) and are interpolated into SQL.
"""

from __future__ import annotations

import json
import logging
import time
from collections.abc import Callable

import psycopg2.extras

from processing.common.pdl import call_pdl_with_retry

logger = logging.getLogger(__name__)

# Auto-retry safeguards (see docs/design/18_pdl_api_generic_caller.md).
DEFAULT_MAX_ATTEMPTS = 3      # max PDL calls per input row before giving up
DEFAULT_STALE_MINUTES = 15    # in_progress older than this = crashed worker

# PDL bulk endpoints cap at 100 records per call.
MAX_BULK_RECORDS = 100

# Default per-month hard stop: 90% of a 1,000,000 requests/month per-endpoint
# ceiling (see docs/design/18_pdl_api_generic_caller.md §Rate limits). Applies
# to cleaners + enrichment; None disables. Adjust to your PDL plan.
DEFAULT_CREDIT_CAP_PER_MONTH = 900_000


class RateLimiter:
    """Minimal single-process pacer. Enforces a minimum interval between calls
    so a worker stays under PDL's per-minute request ceiling. Create ONE per
    `drain()` loop and reuse it across batches so `_next_allowed` persists —
    a fresh limiter per batch lets the first call of every batch skip pacing.
    Advisory only; the real account-wide throttle is the 429/Retry-After
    handling in common/pdl."""

    def __init__(self, requests_per_minute, *,
                 sleep_fn=time.sleep, time_fn=time.monotonic):
        self._min_interval = 60.0 / requests_per_minute if requests_per_minute else 0.0
        self._sleep = sleep_fn
        self._time = time_fn
        self._next_allowed = None

    def wait(self):
        if not self._min_interval:
            return
        now = self._time()
        if self._next_allowed is not None and now < self._next_allowed:
            self._sleep(self._next_allowed - now)
            now = self._time()
        self._next_allowed = now + self._min_interval


# ---------------------------------------------------------------------------- #
# Shared module-level helpers — used by BOTH PDLCaller and BulkPDLCaller.
# ---------------------------------------------------------------------------- #

def pending_count(conn, driver_view):
    """How many rows the driver view still exposes as pending."""
    with conn.cursor() as cur:
        cur.execute(f"SELECT count(*) FROM {driver_view}")
        return cur.fetchone()[0]


def credits_spent_today(conn, audit_table):
    """Successful calls today (one PDL credit each) — for the per-day cap.
    PDL bills per successful record, so count 200s. Meaningful only
    for billed endpoints; cleaners leave credit_cap_per_day=None."""
    with conn.cursor() as cur:
        cur.execute(
            f"SELECT count(*) FROM {audit_table} "
            f"WHERE response_status = 200 AND called_at::date = current_date"
        )
        return cur.fetchone()[0]


def calls_this_month(conn, audit_table):
    """ALL PDL calls this calendar month (any HTTP status) — for the per-month
    cap. PDL's per-endpoint monthly ceiling counts every request (200s, 404s,
    5xx, retries), not just successes, so this must NOT filter on
    response_status. Distinct from credits_spent_today, which
    counts billed successes for the per-day billing cap."""
    with conn.cursor() as cur:
        cur.execute(
            f"SELECT count(*) FROM {audit_table} "
            f"WHERE called_at >= date_trunc('month', now())"
        )
        return cur.fetchone()[0]


def cap_reached(conn, audit_table, credit_cap_per_day, credit_cap_per_month):
    """True when either the daily billing cap or the monthly request cap for
    this endpoint is already spent. Consulted before any claim. The per-day cap
    counts billed successes (200s); the per-month cap counts ALL calls."""
    if (credit_cap_per_day is not None
            and credits_spent_today(conn, audit_table) >= credit_cap_per_day):
        return True
    if (credit_cap_per_month is not None
            and calls_this_month(conn, audit_table) >= credit_cap_per_month):
        return True
    return False


def claim_under_cap(conn, audit_table, credit_cap_per_day, credit_cap_per_month, claim_fn):
    """Serialize cap-check + claim under ONE advisory xact lock so N concurrent
    workers can't each observe headroom and collectively overshoot the cap.
    The lock is held from here until claim_fn commits. On a spent
    cap, log + rollback (releasing the lock) and return []. Any error rolls back
    so the connection is never left in an aborted transaction."""
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", (audit_table,))
        if cap_reached(conn, audit_table, credit_cap_per_day, credit_cap_per_month):
            conn.rollback()
            logger.info("[cap] %s cap already spent; skipping batch", audit_table)
            return []
        return claim_fn()  # commits internally -> releases the advisory lock
    except Exception:
        conn.rollback()
        raise


def finalize_columns(status_column, status, extras):
    """Build the SET list for a queue-finalize UPDATE, deduped. The framework
    always clears worker_id / claimed_at and writes the status column; those
    win over any same-named key a subclass returned in `extras`, so a column
    can never be specified twice ('column specified more than once')."""
    cols = dict(extras or {})
    cols[status_column] = status
    cols["worker_id"] = None
    cols["claimed_at"] = None
    set_sql = [f"{c} = %s" for c in cols]
    return set_sql, list(cols.values())


def reclaim_stale_simple(conn, queue_table, status_column, stale_minutes):
    """Single-record recovery: rows stuck in_progress past the threshold go back
    to pending (a single-record call is idempotent to retry — no saved bulk
    response to replay). `stale_minutes` is clamped to >= 1 so a fractional
    value can't floor to 0 and requeue rows that are still being processed.
    Returns the number requeued."""
    minutes = max(1, int(stale_minutes))
    with conn.cursor() as cur:
        cur.execute(
            f"""
            UPDATE {queue_table} q
            SET    {status_column} = 'pending',
                   worker_id = NULL, claimed_at = NULL
            WHERE  q.{status_column} = 'in_progress'
              AND  q.claimed_at < now() - %s::interval
            """,
            (f"{minutes} minutes",),
        )
        n = cur.rowcount
    conn.commit()
    return n


def parse_drain_rpm(prog, argv, default_rpm):
    """Parse a cleaner drainer's CLI: `drain [--rpm N]`. Steady-state cron runs
    use the default; a one-time backfill of a large queue passes a higher
    `--rpm` to compress the drain without a code/config change (doc 18
    §Backfill vs. steady-state RPM). Returns the chosen rpm."""
    import argparse
    p = argparse.ArgumentParser(prog=prog)
    p.add_argument("command", choices=["drain"])
    p.add_argument("--rpm", type=int, default=default_rpm,
                   help="requests/min pacing (default %(default)s; raise for "
                        "one-time backfills)")
    return p.parse_args(argv).rpm


def requeue_retryable_rows(conn, queue_table, status_column, audit_table, max_attempts):
    """Flip 'error' rows back to 'pending', bounded to max_attempts PDL calls
    per input row. 'not_found' stays terminal. Returns count."""
    with conn.cursor() as cur:
        cur.execute(
            f"""
            WITH attempts AS (
                SELECT input_list_id, count(*) AS n
                FROM   {audit_table} GROUP BY input_list_id
            )
            UPDATE {queue_table} q
            SET    {status_column} = 'pending',
                   worker_id = NULL, claimed_at = NULL
            FROM   attempts a
            WHERE  q.id = a.input_list_id
              AND  q.{status_column} = 'error'
              AND  a.n < %s
            """,
            (max_attempts,),
        )
        n = cur.rowcount
    conn.commit()
    return n


# ---------------------------------------------------------------------------- #
# PDLCaller — single-record cleaner base
# ---------------------------------------------------------------------------- #

class PDLCaller:
    """Single-record PDL endpoint pipeline (the three cleaners). One HTTP call
    per claimed queue row. Subclass and override `build_payload` + `map_status`;
    do NOT override `process_batch`."""

    def __init__(self, *, endpoint_url, driver_view, queue_table,
                 queue_status_column, audit_table, rate_limit_rpm,
                 credit_cap_per_day=None,
                 credit_cap_per_month=DEFAULT_CREDIT_CAP_PER_MONTH):
        self.endpoint_url = endpoint_url
        self.driver_view = driver_view
        self.queue_table = queue_table
        self.queue_status_column = queue_status_column
        self.audit_table = audit_table
        self.rate_limit_rpm = rate_limit_rpm
        self.credit_cap_per_day = credit_cap_per_day
        self.credit_cap_per_month = credit_cap_per_month

    # ------------------------------ hooks ------------------------------ #

    def build_payload(self, claimed_row) -> dict:
        """Return the PDL request body for one claimed row. Default: the driver
        view already shaped it under `request_payload`. Override for endpoints
        whose payload is derived."""
        return claimed_row["request_payload"]

    def map_status(self, response) -> tuple[str, dict]:
        """Map a PDL response to (terminal_queue_status, extra_queue_columns).
        The status must satisfy the queue CHECK constraint. `extra_queue_columns`
        is written onto the queue row alongside the status (empty dict is fine)."""
        raise NotImplementedError

    # --------------------------- framework ----------------------------- #

    def process_batch(self, conn, worker_id, limit=100, *,
                      sleep_fn: Callable[[float], None] = time.sleep, _limiter=None) -> int:
        """Claim up to `limit` pending rows, call PDL once per row, and record +
        finalize each atomically. Returns the number processed; returns 0 early
        when a credit cap is already spent. `_limiter` lets `drain()` share one
        RateLimiter across batches — do not pass it directly."""
        claimed = claim_under_cap(
            conn, self.audit_table, self.credit_cap_per_day, self.credit_cap_per_month,
            lambda: self._claim(conn, worker_id, limit))
        if not claimed:
            return 0
        limiter = _limiter or RateLimiter(self.rate_limit_rpm, sleep_fn=sleep_fn)
        for row in claimed:
            limiter.wait()
            # Single-record cleaners do NOT send metadata.input_list_id — we
            # process one row at a time and know its id locally, so there is no
            # round-trip correlation to do. Keeping it out of the request body
            # also avoids any strict-validation 400 on /v5/*/clean.
            payload = self.build_payload(row)
            result = call_pdl_with_retry(self.endpoint_url, payload)
            status, extras = self.map_status(result)
            self._record_and_finalize(conn, worker_id, row["input_list_id"], payload,
                                      result, status, extras)
        return len(claimed)

    def drain(self, conn, worker_id, *, batch_limit=100,
              sleep_fn: Callable[[float], None] = time.sleep) -> int:
        """Reclaim stale in_progress rows first (crash recovery), then loop
        `process_batch` until the driver view is empty. One RateLimiter is
        shared across every batch so pacing persists. Returns total processed."""
        self.reclaim_stale(conn)
        limiter = RateLimiter(self.rate_limit_rpm, sleep_fn=sleep_fn)
        total = 0
        while pending_count(conn, self.driver_view) > 0:
            n = self.process_batch(conn, worker_id, limit=batch_limit, _limiter=limiter)
            if n == 0:
                break
            total += n
        return total

    def reclaim_stale(self, conn, stale_minutes=DEFAULT_STALE_MINUTES) -> int:
        return reclaim_stale_simple(conn, self.queue_table,
                                    self.queue_status_column, stale_minutes)

    def requeue_retryable(self, conn, max_attempts=DEFAULT_MAX_ATTEMPTS) -> int:
        return requeue_retryable_rows(conn, self.queue_table,
                                      self.queue_status_column, self.audit_table,
                                      max_attempts)

    # --------------------------- internals ----------------------------- #

    def _claim(self, conn, worker_id, limit):
        """Reserve pending rows: flip the status column to in_progress, stamp
        worker_id + claimed_at, via FOR UPDATE SKIP LOCKED on the driver view."""
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                f"""
                WITH picked AS (
                    SELECT input_list_id, request_payload
                    FROM   {self.driver_view}
                    ORDER BY input_list_id
                    FOR UPDATE SKIP LOCKED
                    LIMIT %s
                )
                UPDATE {self.queue_table} q
                SET    {self.queue_status_column} = 'in_progress',
                       worker_id  = %s,
                       claimed_at = clock_timestamp()
                FROM   picked
                WHERE  q.id = picked.input_list_id
                RETURNING q.id AS input_list_id, picked.request_payload
                """,
                (limit, worker_id),
            )
            rows = cur.fetchall()
        conn.commit()
        return rows

    def _record_and_finalize(self, conn, worker_id, input_list_id, request_json,
                             result, status, extras=None):
        """Finalize the queue row and append the audit row in ONE transaction.

        The queue UPDATE is guarded — it only fires if THIS worker still owns the
        row and it is still in_progress. If a stale-reclaim handed the row to
        another worker while our PDL call was in flight, the UPDATE matches 0
        rows: we roll back and do NOT write an audit row (our result is
        superseded; auditing it would inflate the retry-attempt count and, for
        billed endpoints, double-count). rowcount == 1 means we own the row, so
        the audit + finalize commit together — a crash can never leave a charged
        call whose queue row still says in_progress."""
        set_cols, set_params = finalize_columns(self.queue_status_column, status, extras)
        with conn.cursor() as cur:
            cur.execute(
                f"UPDATE {self.queue_table} SET {', '.join(set_cols)} "
                f"WHERE id = %s AND worker_id = %s "
                f"AND {self.queue_status_column} = 'in_progress'",
                set_params + [input_list_id, worker_id],
            )
            if cur.rowcount != 1:
                conn.rollback()
                logger.warning(
                    "finalize lost the row: %s id=%s worker=%s rowcount=%s — "
                    "skipping audit (superseded by a reclaim)",
                    self.queue_table, input_list_id, worker_id, cur.rowcount)
                return
            cur.execute(
                f"""
                INSERT INTO {self.audit_table} (
                    input_list_id, endpoint, request_json,
                    response_status, response_json, latency_ms, error_message
                ) VALUES (%s, %s, %s::jsonb, %s, %s::jsonb, %s, %s)
                """,
                (
                    input_list_id,
                    self.endpoint_url,
                    json.dumps(request_json),
                    result["http_status"],
                    json.dumps(result["body"]) if result["body"] is not None else None,
                    result["latency_ms"],
                    result["error_message"],
                ),
            )
        conn.commit()


# ---------------------------------------------------------------------------- #
# BulkPDLCaller — bulk-batched base (sibling of PDLCaller, no shared chain)
# ---------------------------------------------------------------------------- #

class BulkPDLCaller:
    """Bulk PDL endpoint pipeline (company enrichment). One HTTP request carries
    up to `max_batch_size` claimed rows; the response returns per-record results
    correlated via `metadata.input_list_id`. Billed.

    Subclass overrides the data-shape hooks: `build_bulk_payload`,
    `map_bulk_response`, and the queue-specific data-access methods the base
    calls (`_claim`, `_next_batch_id`, `_record_batch`, `_finalize_batch`,
    `_skip_siblings`, `reclaim_stale`). The base owns the ORCHESTRATION — cap
    checks, claim/call/record/finalize ordering, pacing — so this is a
    template-method base, not a facade."""

    def __init__(self, *, endpoint_url, driver_view, queue_table,
                 queue_status_column, audit_table, rate_limit_rpm,
                 credit_cap_per_day=None,
                 credit_cap_per_month=DEFAULT_CREDIT_CAP_PER_MONTH,
                 max_batch_size=MAX_BULK_RECORDS):
        self.endpoint_url = endpoint_url
        self.driver_view = driver_view
        self.queue_table = queue_table
        self.queue_status_column = queue_status_column
        self.audit_table = audit_table
        self.rate_limit_rpm = rate_limit_rpm
        self.credit_cap_per_day = credit_cap_per_day
        self.credit_cap_per_month = credit_cap_per_month
        self.max_batch_size = max_batch_size

    # ------------------------------ hooks ------------------------------ #

    def build_bulk_payload(self, claimed_rows) -> dict:
        """Return the JSON body for one bulk HTTP call. Must include per-record
        `metadata.input_list_id` so `map_bulk_response` can reconcile results
        back to queue rows."""
        raise NotImplementedError

    def map_bulk_response(self, result, claimed_rows) -> list[tuple[int, str, dict]]:
        """Return [(input_list_id, terminal_status, extras), ...] per claimed
        row. Reconciliation MUST be by `metadata.input_list_id` in each response
        record — order-based reconciliation is a bug (PDL may reorder)."""
        raise NotImplementedError

    # subclass data-access hooks (queue-specific SQL)
    def _claim(self, conn, worker_id, limit, source_list):
        raise NotImplementedError

    def _next_batch_id(self, conn):
        """Sequence value grouping every audit row from one HTTP call. Default
        None for bulk endpoints without a batch sequence."""
        return None

    def _record_batch(self, conn, batch_id, claimed, result):
        """Persist one audit row per claimed record (raw HTTP response). Company-
        specific because the audit columns / bulk_batch_id are per-endpoint.
        Committed on its own, BEFORE finalize, so recovery can replay it."""
        raise NotImplementedError

    def _finalize_batch(self, conn, worker_id, records):
        """Finalize the whole batch in ONE execute_values UPDATE — a per-row
        loop costs one round-trip per record and is orders of magnitude slower
        on a large queue.
        Guarded on worker_id + in_progress so a row a stale-reclaim handed to
        another worker isn't clobbered; losers simply don't update.

        `records` is what `map_bulk_response` returned: [(input_list_id, status,
        extras)]. extras is unused on the bulk path (enrichment writes no extra
        queue columns) — a future bulk endpoint needing per-row extras would use
        a guarded per-row UPDATE instead."""
        updates = [(input_list_id, status, worker_id)
                   for input_list_id, status, _extras in records]
        with conn.cursor() as cur:
            psycopg2.extras.execute_values(
                cur,
                f"""UPDATE {self.queue_table} c
                   SET    {self.queue_status_column} = v.new_status,
                          worker_id = NULL, claimed_at = NULL
                   FROM   (VALUES %s) AS v(id, new_status, wid)
                   WHERE  c.id = v.id::bigint
                     AND  c.worker_id = v.wid
                     AND  c.{self.queue_status_column} = 'in_progress'""",
                updates,
                template="(%s,%s,%s)",
            )
        conn.commit()

    def _skip_siblings(self, conn, batch_id):
        """Post-finalize hook — e.g. collapse duplicate queue rows targeting a
        just-enriched id. Default no-op."""
        return None

    # --------------------------- framework ----------------------------- #

    def process_batch(self, conn, worker_id, limit=MAX_BULK_RECORDS, *,
                      source_list=None,
                      sleep_fn: Callable[[float], None] = time.sleep) -> int:
        """Claim up to min(`limit`, max_batch_size) rows, send them in ONE bulk
        call, persist the whole response, then finalize the queue. Persisting
        the response BEFORE finalizing (two transactions, in that order) is what
        makes a mid-batch crash non-double-charging — `reclaim_stale` replays
        the saved response instead of re-calling PDL. Returns rows processed;
        returns 0 early when a credit cap is already spent."""
        if limit > self.max_batch_size:
            raise ValueError(
                f"limit={limit} exceeds PDL bulk cap ({self.max_batch_size}). "
                f"Split into multiple batches.")
        claimed = claim_under_cap(
            conn, self.audit_table, self.credit_cap_per_day, self.credit_cap_per_month,
            lambda: self._claim(conn, worker_id, limit, source_list))
        if not claimed:
            return 0
        batch_id = self._next_batch_id(conn)
        payload = self.build_bulk_payload(claimed)
        result = call_pdl_with_retry(self.endpoint_url, payload)
        # record-then-finalize (two transactions, in that order) — deliberate for
        # bulk: the whole response is persisted first so a crash before finalize
        # replays from audit instead of re-charging PDL.
        self._record_batch(conn, batch_id, claimed, result)
        records = self.map_bulk_response(result, claimed)
        self._finalize_batch(conn, worker_id, records)
        self._skip_siblings(conn, batch_id)
        return len(claimed)

    def drain(self, conn, worker_id, *, source_list=None,
              sleep_fn: Callable[[float], None] = time.sleep) -> int:
        """Reclaim stale rows first (crash recovery — replay-from-audit for the
        billed endpoint), then loop `process_batch` until the queue is empty.
        Returns total processed."""
        self.reclaim_stale(conn, source_list=source_list)
        limiter = RateLimiter(self.rate_limit_rpm, sleep_fn=sleep_fn)
        total = 0
        while pending_count(conn, self.driver_view) > 0:
            limiter.wait()
            n = self.process_batch(conn, worker_id, limit=self.max_batch_size,
                                   source_list=source_list)
            if n == 0:
                break
            total += n
        return total

    def reclaim_stale(self, conn, stale_minutes=DEFAULT_STALE_MINUTES,
                      source_list=None) -> tuple[int, int]:
        """Bulk crash recovery: replay completed audit rows onto their stuck
        queue rows (no re-charge), then requeue rows with no saved audit. Returns
        (replayed_from_audit, requeued). The status mapping is endpoint-specific,
        so a subclass that needs recovery overrides this. Base default is a SAFE
        NO-OP (not NotImplementedError) so drain(), which calls reclaim_stale
        unconditionally on entry, can't crash for a subclass that forgot to
        override it."""
        logger.warning(
            "%s.reclaim_stale not overridden — skipping stale recovery",
            type(self).__name__)
        return (0, 0)

    def requeue_retryable(self, conn, max_attempts=DEFAULT_MAX_ATTEMPTS) -> int:
        return requeue_retryable_rows(conn, self.queue_table,
                                      self.queue_status_column, self.audit_table,
                                      max_attempts)
