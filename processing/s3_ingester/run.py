"""One-delivery orchestrator (`run.py`).

Runs one delivery end-to-end in a single local process:

    Finder → Loader → PDL projection (if PDL source) → finalize pdl_delivery

This is the CLI entry point for ingesting a PDL delivery. The script chains
the Python modules sequentially in one process. State passing between
modules is via the catalog tables (`ingestion_run_id` flows from Finder's
return → Loader's input).

Each module remains independently invokable (their own CLIs work standalone
for ad-hoc debugging or re-running a single step). See
docs/design/02_pipeline_design.md Section 6.

`--pipeline-version` (optional, default 'local') is recorded on the
catalog.pipeline_run row Finder writes; pin it to a git SHA / release tag
when the run should be traceable to a code version.

Source-specific post-load:
  Currently hardcoded — `source.startswith("pdl_")` triggers PDL deltas
  projection via `pdl_projection_runner.run_pdl_projection`. If other
  sources ever need post-load steps, this should generalize to a
  YAML-declared `post_load:` key.

Failure handling:
  Exceptions from any step propagate. Finder's catalog state already
  reflects whatever it succeeded at writing; Loader marks `ingestion_run`
  as `'failed'` on its own failures (separate transaction). The projection
  step is idempotent on re-run, so a failure between Loader-success and
  projection-success can be recovered by re-running just `run_pdl_projection`
  (or the whole `run.py` — Loader will see no pending files and short-circuit).

Local CLI (against the docker-compose Postgres + local S3):

    DATABASE_URL='postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl' \\
    AWS_ENDPOINT_URL=http://localhost:9000 \\
    AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=local \\
    python -m processing.s3_ingester.run \\
        --source pdl_full_local \\
        --delivery-date 2026_05_22 \\
        --max-concurrency 4
"""

from __future__ import annotations

import argparse
import json
import logging
import os
from typing import Any

from processing.common.db import connect
from processing.common.logging_setup import configure_logging
from processing.s3_ingester.delivery_loader import load_pending_files
from processing.s3_ingester.finder import (
    _DEFAULT_PIPELINE_VERSION,
    discover_delivery,
)
from processing.s3_ingester.pdl_projection_runner import run_pdl_projection

logger = logging.getLogger(__name__)


def run_delivery(
    *,
    source: str,
    delivery_date: str,
    db_dsn: str,
    max_concurrency: int = 1,
    pipeline_version: str = _DEFAULT_PIPELINE_VERSION,
) -> dict[str, Any]:
    """End-to-end one-delivery orchestrator: Finder → Loader → projection.

    Args:
      source:           Source name (resolves to configs/<source>.yaml).
      delivery_date:    yyyy_mm_dd (PDL S3 prefix format).
      db_dsn:           psycopg2 connection string for the application DB.
      max_concurrency:  Loader concurrency (1 = sequential; >1 = thread pool).
      pipeline_version: Recorded on pipeline_run.pipeline_version (e.g. a
                        git SHA / release tag). Default 'local'.

    Returns:
      Summary dict with each step's output.

    Raises:
      Anything Finder, Loader, or pdl_projection_runner raises. On any
      post-Finder failure for a PDL source, pdl_delivery is marked 'failed'
      in a fresh transaction before the exception propagates.
    """
    is_pdl = source.startswith("pdl_")
    iso_delivery_date = delivery_date.replace("_", "-") if is_pdl else None

    # 1. Finder — discovers S3 files, writes pipeline_run + ingestion_run +
    #    N pending ingestion_file rows + pdl_delivery (PDL only).
    logger.info("finder: source=%s delivery_date=%s", source, delivery_date)
    ingestion_run_id = discover_delivery(
        source=source,
        delivery_date=delivery_date,
        db_dsn=db_dsn,
        pipeline_version=pipeline_version,
    )

    try:
        # 2. Loader — processes pending ingestion_file rows; finalizes
        #    ingestion_run with totals.
        logger.info("loader: ingestion_run_id=%s", ingestion_run_id)
        loader_summary = load_pending_files(
            source=source,
            ingestion_run_id=ingestion_run_id,
            db_dsn=db_dsn,
            max_concurrency=max_concurrency,
        )
        logger.info(
            "loader done: files=%s rows=%s bytes=%s",
            loader_summary.get("file_count"),
            loader_summary.get("total_row_count"),
            loader_summary.get("total_bytes"),
        )

        # 3. Source-specific post-load. PDL: project raw deltas into catalog
        #    ledger (pdl_id_aliases, pdl_inactive, merge_events).
        projection_summary: dict[str, Any] | None = None
        if is_pdl:
            # raw.project_pdl_deltas takes a date type; convert from PDL's
            # yyyy_mm_dd S3-prefix format to ISO yyyy-mm-dd.
            logger.info("projection: delivery_date=%s", iso_delivery_date)
            projection_summary = run_pdl_projection(
                delivery_date=iso_delivery_date,
                db_dsn=db_dsn,
            )

        # 4. Finalize pdl_delivery (PDL only). Finder leaves status='received'
        #    after the initial INSERT; this is the only place the lifecycle
        #    advances to 'success'. row_counts + per-delta scalars are derived
        #    from catalog.ingestion_file aggregations (the per-file row counts
        #    file_ingester wrote).
        if is_pdl:
            logger.info("finalize: delivery_date=%s", iso_delivery_date)
            _finalize_pdl_delivery_success(
                db_dsn=db_dsn,
                iso_delivery_date=iso_delivery_date,
                ingestion_run_id=ingestion_run_id,
            )
    except Exception as exc:
        if is_pdl:
            _finalize_pdl_delivery_failed(
                db_dsn=db_dsn,
                iso_delivery_date=iso_delivery_date,
                error_message=str(exc),
            )
        raise

    return {
        "source": source,
        "delivery_date": delivery_date,
        "ingestion_run_id": ingestion_run_id,
        "loader": loader_summary,
        "projection": projection_summary,
        "succeeded": True,
    }


# -----------------------------------------------------------------------------
# pdl_delivery lifecycle (PDL only). Finder INSERTs status='received'; this
# module owns the terminal transition. Non-PDL sources don't have a delivery
# table — ingestion_run is the only run-level record.
# -----------------------------------------------------------------------------

def _finalize_pdl_delivery_success(
    *,
    db_dsn: str,
    iso_delivery_date: str,
    ingestion_run_id: str,
) -> None:
    """Mark pdl_delivery 'success' with row_counts + per-delta scalars.

    Aggregates catalog.ingestion_file by target_table for this run, then
    UPDATEs the single pdl_delivery row keyed by delivery_date. Runs in its
    own connection / transaction — independent of the load transactions.
    """
    with connect(db_dsn) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT target_table, COALESCE(SUM(row_count), 0)::bigint
              FROM catalog.ingestion_file
             WHERE ingestion_run_id = %s
               AND status = 'success'
             GROUP BY target_table
            """,
            (ingestion_run_id,),
        )
        per_target = dict(cur.fetchall())

        # row_counts jsonb is keyed by raw target table (e.g.
        # 'raw.pdl_person') — keep it dataset-agnostic.
        row_counts = {tbl: int(n) for tbl, n in per_target.items()}

        merge_count    = int(per_target.get("raw.pdl_merged_records", 0))
        deleted_count  = int(per_target.get("raw.pdl_deleted_records", 0))
        opted_out_count = int(per_target.get("raw.pdl_opted_out_records", 0))

        cur.execute(
            """
            UPDATE catalog.pdl_delivery
               SET status                = 'success',
                   completed_at          = now(),
                   row_counts            = %s::jsonb,
                   pdl_merge_event_count = %s,
                   pdl_deleted_count     = %s,
                   pdl_opted_out_count   = %s,
                   error_message         = NULL,
                   updated_at            = now()
             WHERE delivery_date = %s
            """,
            (
                json.dumps(row_counts),
                merge_count, deleted_count, opted_out_count,
                iso_delivery_date,
            ),
        )


def _finalize_pdl_delivery_failed(
    *,
    db_dsn: str,
    iso_delivery_date: str,
    error_message: str,
) -> None:
    """Mark pdl_delivery 'failed' with the propagating exception's message.

    Best-effort in its own fresh connection — never raises. Re-raising here
    would mask the original exception caller is about to see.

    Keying on delivery_date (rather than ingestion_run_id)
    is intentional: pdl_delivery has one row per delivery_date. A re-run
    against the same delivery overwrites the previous run's status /
    error_message — last-write-wins is the desired semantics for an
    operator-facing "is this delivery loaded yet" view.
    """
    try:
        with connect(db_dsn) as conn, conn.cursor() as cur:
            cur.execute(
                """
                UPDATE catalog.pdl_delivery
                   SET status        = 'failed',
                       completed_at  = now(),
                       error_message = %s,
                       updated_at    = now()
                 WHERE delivery_date = %s
                """,
                (error_message, iso_delivery_date),
            )
    except Exception as secondary_exc:
        # Best-effort: the original load exception is what the caller needs
        # to see. Swallow secondary failures, but log them so
        # a broken catalog write isn't invisible in the run log.
        logger.warning(
            "pdl_delivery failure-finalization lost for delivery_date=%r: %r",
            iso_delivery_date, secondary_exc,
        )


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

def _cli() -> int:
    configure_logging()
    parser = argparse.ArgumentParser(
        description="Run one delivery end-to-end "
                    "(Finder → Loader → projection → finalize).",
    )
    parser.add_argument("--source", required=True,
                        help="source name; resolves to configs/<source>.yaml")
    parser.add_argument("--delivery-date", required=True,
                        help="literal yyyy_mm_dd delivery prefix (e.g. 2026_05_22)")
    parser.add_argument("--max-concurrency", type=int, default=1,
                        help="Loader max_concurrency (1 = sequential; default 1)")
    parser.add_argument("--pipeline-version", default=_DEFAULT_PIPELINE_VERSION,
                        help=f"pipeline_version label written on pipeline_run "
                             f"(default: {_DEFAULT_PIPELINE_VERSION!r}; "
                             "e.g. pin to a git SHA / release tag).")
    args = parser.parse_args()

    db_dsn = os.environ.get("DATABASE_URL")
    if not db_dsn:
        logger.error("DATABASE_URL env var is required")
        return 2

    logger.info(
        "delivery start: source=%s delivery_date=%s pipeline_version=%s",
        args.source, args.delivery_date, args.pipeline_version,
    )
    summary = run_delivery(
        source=args.source,
        delivery_date=args.delivery_date,
        db_dsn=db_dsn,
        max_concurrency=args.max_concurrency,
        pipeline_version=args.pipeline_version,
    )
    print(json.dumps(summary, indent=2, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
