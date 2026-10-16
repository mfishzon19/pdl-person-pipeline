"""Per-delivery Loader (`delivery_loader.py`).

Run once per delivery (by run.py or its own CLI). Reads the delivery's pending
`catalog.ingestion_file` rows (written upfront by Finder), loops over them
calling the per-file primitive `ingest_file()` (in `file_ingester.py`),
and finalizes the `catalog.ingestion_run` row with totals.

Concurrency is in-process: sequential by default, optional
`ThreadPoolExecutor`-based parallelism (one psycopg2 session per worker)
when `--max-concurrency > 1`. No inter-process chunking — see
docs/design/02_pipeline_design.md Section 6.

Source-level constants (column_list, copy_options, bucket, region,
partition_column, partition_value_type) live in YAML configs at
`processing/s3_ingester/configs/<source>.yaml`. Per-file values
(s3_key, target_table, partition_value) come from the `ingestion_file` rows
that Finder wrote.

Local CLI:
    DATABASE_URL='postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl' \\
    AWS_ENDPOINT_URL=http://localhost:9000 \\
    AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=local \\
    python -m processing.s3_ingester.delivery_loader \\
        --source pdl_full_local \\
        --ingestion-run-id <uuid> \\
        --max-concurrency 4
"""

from __future__ import annotations

import argparse
import json
import logging
import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

import yaml
from psycopg2 import sql

from processing.common.db import connect
from processing.common.logging_setup import configure_logging
from processing.s3_ingester.file_ingester import ingest_file

logger = logging.getLogger(__name__)

# Per-source YAML configs live next to this module.
_CONFIGS_DIR = Path(__file__).parent / "configs"

# YAML keys required for every source.
_REQUIRED_CONFIG_KEYS = frozenset({
    "column_list", "copy_options", "bucket", "region",
})

# Optional partition keys — must appear together (partitioned mode) or
# both be absent (flat-table mode).
_PARTITION_CONFIG_KEYS = frozenset({
    "partition_column", "partition_value_type",
})

# Allowed values for the optional `replace_strategy` key:
#   'full'          — TRUNCATE each parent target_table at delivery start
#                     (every delivery is a full snapshot; PDL).
#   'per_partition' — per-file TRUNCATE+COPY of each leaf only, no parent-level
#                     reset (sources whose partitions are delivered
#                     independently). Default if the key is absent.
_ALLOWED_REPLACE_STRATEGIES = frozenset({"full", "per_partition"})


# -----------------------------------------------------------------------------
# Public entry point
# -----------------------------------------------------------------------------

def load_pending_files(
    *,
    source: str,
    ingestion_run_id: str,
    db_dsn: str,
    max_concurrency: int = 1,
) -> dict[str, Any]:
    """Load all pending files for one ingestion_run; finalize the run row.

    Args:
      source:             Name of the source. Resolves to
                          `configs/<source>.yaml` for source-level constants.
      ingestion_run_id:   catalog.ingestion_run.ingestion_run_id (uuid).
                          Finder must have written this row plus N pending
                          `ingestion_file` rows before the Loader runs.
      db_dsn:             Postgres connection string.
      max_concurrency:    1 = sequential loop. >1 = ThreadPoolExecutor with
                          that many concurrent psycopg2 sessions.

    Returns:
      A summary dict (also persisted in `ingestion_run`):
        {ingestion_run_id, source, file_count, total_row_count,
         total_bytes, succeeded: True}

    Raises:
      FileNotFoundError, ValueError — config file missing or malformed.
      RuntimeError                  — empty pending list (Finder should
                                      always have written ≥1 row; an empty
                                      list is treated as a bug, the run is
                                      marked 'failed', and the exception
                                      propagates).
      psycopg2.Error subclasses     — DB-side failures bubble up after the
                                      `ingestion_run` row is marked failed.
      Exception                     — any per-file failure (raised by
                                      `ingest_file()`) — same handling.
    """
    config = _load_source_config(source)
    is_partitioned = "partition_column" in config

    conn = connect(db_dsn)
    try:
        files = _select_pending_files(conn, ingestion_run_id)

        # Empty delivery is an anomaly: Finder raises when it discovers no
        # files, so 0 pending rows means something upstream went wrong.
        if not files:
            err = (
                f"ingestion_run {ingestion_run_id} has no pending "
                "ingestion_file rows (Finder bug or upstream failure)"
            )
            _finalize_run(
                conn, ingestion_run_id,
                status="failed",
                error_message=err,
            )
            raise RuntimeError(err)

        # replace_strategy='full' (e.g. PDL): TRUNCATE every target_table of
        # the source before the load — including optional file groups with no
        # files this delivery. Each delivery is a complete snapshot, so any
        # previously-loaded rows would otherwise survive. Per-partition
        # replacement alone wouldn't catch that.
        # Default ('per_partition'): skipped — each partition is
        # independently latest-only and stale-data risk doesn't apply.
        if config.get("replace_strategy") == "full":
            _truncate_target_tables(conn, files, config)

        # Run the load — sequential or concurrent.
        try:
            if max_concurrency == 1:
                for f in files:
                    _load_one(f, config, db_dsn, is_partitioned)
            else:
                with ThreadPoolExecutor(max_workers=max_concurrency) as ex:
                    futures = {
                        ex.submit(_load_one, f, config, db_dsn, is_partitioned): f
                        for f in files
                    }
                    for fut in as_completed(futures):
                        fut.result()  # raises on first per-file failure
        except Exception as exc:
            _finalize_run(
                conn, ingestion_run_id,
                status="failed",
                error_message=str(exc),
            )
            raise

        # Aggregate from the catalog so totals are authoritative.
        file_count, total_row_count, total_bytes = _aggregate_from_files(
            conn, ingestion_run_id,
        )
        _finalize_run(
            conn, ingestion_run_id,
            status="success",
            file_count=file_count,
            total_row_count=total_row_count,
            total_bytes=total_bytes,
        )

        return {
            "ingestion_run_id": ingestion_run_id,
            "source": source,
            "file_count": file_count,
            "total_row_count": int(total_row_count),
            "total_bytes": int(total_bytes) if total_bytes is not None else None,
            "succeeded": True,
        }
    finally:
        conn.close()


# -----------------------------------------------------------------------------
# Config loading
# -----------------------------------------------------------------------------

def _load_source_config(source: str) -> dict[str, Any]:
    """Load and validate `configs/<source>.yaml`."""
    path = _CONFIGS_DIR / f"{source}.yaml"
    if not path.exists():
        raise FileNotFoundError(f"source config not found: {path}")

    with path.open() as f:
        config = yaml.safe_load(f)

    if not isinstance(config, dict):
        raise ValueError(f"{path}: expected a YAML mapping, got {type(config).__name__}")

    missing = _REQUIRED_CONFIG_KEYS - config.keys()
    if missing:
        raise ValueError(
            f"{path}: missing required keys: {sorted(missing)}"
        )

    # Partition keys: all-or-none.
    partition_present = _PARTITION_CONFIG_KEYS & config.keys()
    if partition_present and partition_present != _PARTITION_CONFIG_KEYS:
        raise ValueError(
            f"{path}: partition_column and partition_value_type must both be "
            "present (partitioned mode) or both absent (flat-table mode); got "
            f"only {sorted(partition_present)}"
        )

    # replace_strategy: optional; defaults to per_partition if absent.
    if "replace_strategy" in config:
        rs = config["replace_strategy"]
        if rs not in _ALLOWED_REPLACE_STRATEGIES:
            raise ValueError(
                f"{path}: replace_strategy must be one of "
                f"{sorted(_ALLOWED_REPLACE_STRATEGIES)}, got {rs!r}"
            )

    return config


# -----------------------------------------------------------------------------
# Catalog reads / writes
# -----------------------------------------------------------------------------

def _truncate_target_tables(
    conn,
    files: list[dict[str, Any]],
    config: dict[str, Any] | None = None,
) -> None:
    """TRUNCATE every target_table of the source: those referenced by this
    delivery's files plus every `file_groups[].target_table` in the config.

    Used by replace_strategy='full' sources (PDL): every delivery is a
    complete snapshot, so previous deliveries' leaves should be wiped before
    loading. Per-partition replacement (default) wouldn't catch the case
    where a previous delivery's partition_value is absent from this one,
    leaving stale rows under the parent.

    Including the config's file groups matters for optional groups (PDL's
    MERGED / DELETED / OPTED_OUT deltas): when a delivery has no files for
    one, its raw table must still be emptied, or raw.project_pdl_deltas()
    would re-project the previous delivery's delta rows under the new date.

    Committed in its own transaction (separate from the per-file load loop)
    so the AccessExclusiveLock TRUNCATE acquires doesn't span the entire
    load. Acceptable because ingests are run one at a time per source (an
    operator-driven CLI) — concurrent readers aren't expected mid-load.

    TRUNCATE on a partitioned parent cascades to every leaf automatically
    (Postgres default behavior). Empty leaves remain in the schema for
    partition_values absent from this delivery; they're harmless (zero rows)
    but accumulate over time. Cleanup of empty orphan leaves is a separate
    ops concern.
    """
    unique_targets = sorted(
        {f["target_table"] for f in files}
        | {fg["target_table"] for fg in (config or {}).get("file_groups", [])}
    )
    with conn:
        with conn.cursor() as cur:
            for target in unique_targets:
                schema, table = target.split(".", 1)
                cur.execute(
                    sql.SQL("TRUNCATE TABLE {schema}.{table}").format(
                        schema=sql.Identifier(schema),
                        table=sql.Identifier(table),
                    )
                )


def _select_pending_files(conn, ingestion_run_id: str) -> list[dict[str, Any]]:
    """Read pending ingestion_file rows for this run, ordered deterministically."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT ingestion_file_id, target_table, s3_key, partition_value "
            "FROM catalog.ingestion_file "
            "WHERE ingestion_run_id = %s AND status = 'pending' "
            "ORDER BY ingestion_file_id",
            (ingestion_run_id,),
        )
        return [
            {
                "ingestion_file_id": str(r[0]),
                "target_table": r[1],
                "s3_key": r[2],
                "partition_value": r[3],
            }
            for r in cur.fetchall()
        ]


def _aggregate_from_files(
    conn,
    ingestion_run_id: str,
) -> tuple[int, int, int | None]:
    """Authoritative totals: count + sum row_count + sum size_bytes for SUCCESSFUL files.

    Always returns a row (COUNT(*) + SUM aggregates over zero rows still yield
    one row); the assert narrows fetchone()'s `tuple | None` for the caller.
    """
    with conn.cursor() as cur:
        cur.execute(
            "SELECT COUNT(*), COALESCE(SUM(row_count), 0), SUM(size_bytes) "
            "FROM catalog.ingestion_file "
            "WHERE ingestion_run_id = %s AND status = 'success'",
            (ingestion_run_id,),
        )
        row = cur.fetchone()
        assert row is not None  # aggregate query always returns one row
        return row


def _finalize_run(
    conn,
    ingestion_run_id: str,
    *,
    status: str,
    file_count: int | None = None,
    total_row_count: int | None = None,
    total_bytes: int | None = None,
    error_message: str | None = None,
) -> None:
    """UPDATE catalog.ingestion_run with terminal status + totals."""
    with conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE catalog.ingestion_run
                   SET status            = %s,
                       total_file_count  = COALESCE(%s, total_file_count),
                       total_row_count   = COALESCE(%s, total_row_count),
                       total_bytes       = COALESCE(%s, total_bytes),
                       ended_at          = now(),
                       duration_seconds  = EXTRACT(EPOCH FROM (now() - started_at)),
                       error_message     = COALESCE(%s, error_message)
                 WHERE ingestion_run_id  = %s
                """,
                (status, file_count, total_row_count, total_bytes,
                 error_message, ingestion_run_id),
            )


# -----------------------------------------------------------------------------
# Per-file dispatch
# -----------------------------------------------------------------------------

def _load_one(
    file_row: dict[str, Any],
    config: dict[str, Any],
    db_dsn: str,
    is_partitioned: bool,
) -> int:
    """Load one pending file via the generic ingest_file() primitive."""
    schema, table = file_row["target_table"].split(".", 1)
    return ingest_file(
        ingestion_file_id     = file_row["ingestion_file_id"],
        schema                = schema,
        table                 = table,
        column_list           = config["column_list"],
        copy_options          = config["copy_options"],
        bucket                = config["bucket"],
        s3_key                = file_row["s3_key"],
        region                = config["region"],
        db_dsn                = db_dsn,
        partition_column      = config.get("partition_column") if is_partitioned else None,
        partition_value       = file_row["partition_value"]    if is_partitioned else None,
        partition_value_type  = config.get("partition_value_type") if is_partitioned else None,
    )


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

def _cli() -> int:
    configure_logging()
    parser = argparse.ArgumentParser(
        description="Load all pending files for one catalog.ingestion_run.",
    )
    parser.add_argument("--source", required=True,
                        help="source name; resolves to configs/<source>.yaml")
    parser.add_argument("--ingestion-run-id", required=True,
                        help="catalog.ingestion_run uuid")
    parser.add_argument("--max-concurrency", type=int, default=1,
                        help="concurrent psycopg2 sessions (default 1 = sequential)")
    args = parser.parse_args()

    db_dsn = os.environ.get("DATABASE_URL")
    if not db_dsn:
        logger.error("DATABASE_URL env var is required")
        return 2

    summary = load_pending_files(
        source=args.source,
        ingestion_run_id=args.ingestion_run_id,
        db_dsn=db_dsn,
        max_concurrency=args.max_concurrency,
    )
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
