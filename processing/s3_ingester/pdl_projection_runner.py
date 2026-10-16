"""PDL deltas → catalog ledger projection runner (`pdl_projection_runner.py`).

Thin Python wrapper around `SELECT raw.project_pdl_deltas(:delivery_date)`.
Calls the Flyway-owned SQL function, returns its jsonb summary.

Why a dedicated module:
  - `run.py` imports `run_pdl_projection` and calls it after the Loader
    finishes. Keeps `run.py` a thin orchestrator with no SQL inline.
  - The CLI below re-runs just the projection step for one delivery
    (e.g. after fixing a failure between Loader-success and projection).

The SQL function (`R__function_project_pdl_deltas.sql`) is idempotent on
re-run for the same delivery_date (ON CONFLICT DO NOTHING + NOT EXISTS),
so this wrapper inherits idempotency.

Spec:
  - Same DB connection contract as the Loader (DATABASE_URL env var).
  - Returns the jsonb summary the SQL function emits:
      {
        "delivery_date": "2026-05-22",
        "observed_at": "2026-05-22T00:00:00+00:00",
        "pdl_id_aliases_inserted": <int>,
        "pdl_inactive_deleted": <int>,
        "pdl_inactive_opted_out": <int>,
        "merge_events_inserted": <int>
      }
  - RAISE inside the SQL function rolls back the projection transaction
    (atomic). Any psycopg2 error propagates.

Local CLI:
    DATABASE_URL='postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl' \\
    python -m processing.s3_ingester.pdl_projection_runner \\
        --delivery-date 2026-05-22
    # stdout: <jsonb summary as JSON>

Note the date format: this CLI takes ISO `yyyy-mm-dd` (matches the
`date` column type on `catalog.ingestion_run.delivery_date`). The Finder
takes `yyyy_mm_dd` (the literal PDL S3 prefix); `run.py` converts between
them when chaining the two.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
from typing import Any

from processing.common.db import connect, fetch_one, transaction
from processing.common.logging_setup import configure_logging

logger = logging.getLogger(__name__)


# ISO date format yyyy-mm-dd.
_ISO_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def run_pdl_projection(
    *,
    delivery_date: str,
    db_dsn: str,
) -> dict[str, Any]:
    """Invoke raw.project_pdl_deltas for the given delivery_date.

    Args:
      delivery_date: ISO yyyy-mm-dd literal. Passed verbatim to Postgres
                     which casts to date.
      db_dsn:        psycopg2 connection string.

    Returns:
      The jsonb summary returned by the SQL function (see module docstring
      for shape). Re-run safe — idempotent on the same delivery_date.

    Raises:
      ValueError              — delivery_date doesn't match yyyy-mm-dd.
      processing.common.db.DBOpsError subclasses — DB-side errors propagate
                              (function RAISE → QueryError, connection
                              failure → ConnectionFailed, etc.).
    """
    if not _ISO_DATE_RE.fullmatch(delivery_date):
        raise ValueError(
            f"delivery_date must be 'yyyy-mm-dd' (ISO), got {delivery_date!r}"
        )

    conn = connect(db_dsn)
    try:
        with transaction(conn):
            row = fetch_one(
                conn,
                "SELECT raw.project_pdl_deltas(%s)",
                (delivery_date,),
            )
        assert row is not None  # SELECT of a function always returns one row
        (summary,) = row
        return summary
    finally:
        conn.close()


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

def _cli() -> int:
    configure_logging()
    parser = argparse.ArgumentParser(
        description="Project raw PDL delta tables into catalog ledger for one "
                    "delivery_date. Wraps SELECT raw.project_pdl_deltas(...). "
                    "Prints jsonb summary on stdout.",
    )
    parser.add_argument("--delivery-date", required=True,
                        help="ISO yyyy-mm-dd (e.g. 2026-05-22). Note: "
                             "Finder takes yyyy_mm_dd; this takes yyyy-mm-dd "
                             "(matches catalog.ingestion_run.delivery_date type).")
    args = parser.parse_args()

    db_dsn = os.environ.get("DATABASE_URL")
    if not db_dsn:
        logger.error("DATABASE_URL env var is required")
        return 2

    summary = run_pdl_projection(
        delivery_date=args.delivery_date,
        db_dsn=db_dsn,
    )
    print(json.dumps(summary, indent=2, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
