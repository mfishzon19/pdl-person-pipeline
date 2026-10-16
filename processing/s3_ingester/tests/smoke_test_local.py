"""Local smoke test for the S3 Ingester framework.

NOT a pytest. A standalone script that exercises the Loader (and optionally
Finder) end-to-end against the local docker-compose Postgres.

Two modes (--mode):

  seeded   (default; no S3 needed)
    Hand-seeds catalog.pipeline_run + ingestion_run + 3 ingestion_file rows
    with synthetic s3_keys, patches the ingester's boto3 client to serve a
    10-row fake file per key, then runs the Loader. Validates the Loader,
    the COPY path and the catalog lifecycle without touching S3 or Finder.

  finder   (requires a delivery in S3 — local MinIO via `make dev-up-ingester`)
    Calls processing.s3_ingester.finder.discover_delivery() against S3
    for the given --delivery-date, then truncates ingestion_file rows down
    to --limit-files (default 5) before running the Loader. Validates the
    Finder + Loader path end-to-end against real PDL-shaped bytes.

Prerequisites (run from repo root, with the pdl_test conda env active):

  conda activate pdl_test
  make dev-up            # postgres + flyway-init (schema applied)
  # finder mode also needs MinIO seeded with the fixture:
  make dev-up-ingester

Then run one of:

  # --- seeded mode (no S3, fast)
  DATABASE_URL='postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl' \\
       python -m processing.s3_ingester.tests.smoke_test_local

  # --- finder mode (local MinIO + local Postgres)
  AWS_ENDPOINT_URL=http://localhost:9000 \\
  AWS_ACCESS_KEY_ID=minio_local AWS_SECRET_ACCESS_KEY=minio_local_dev \\
  DATABASE_URL='postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl' \\
       python -m processing.s3_ingester.tests.smoke_test_local \\
           --mode finder \\
           --source pdl_full_local \\
           --delivery-date 2026_05_22 \\
           --limit-files 5

What you should see on a clean seeded run:

  === mode: seeded — seeding catalog rows ===
  pipeline_run_id  = <random-uuid>
  ingestion_run_id = <random-uuid>

  === running delivery_loader ===
  {
    "ingestion_run_id": "<random-uuid>",
    "source": "pdl_full",
    "file_count": 3,
    "total_row_count": 30,
    "total_bytes": null,
    "succeeded": true
  }

  === verification ===
  ingestion_file rows:
    pv=0  status=success  row_count=10  err=None
    pv=1  status=success  row_count=10  err=None
    pv=2  status=success  row_count=10  err=None

  ingestion_run: status=success  file_count=3  total_rows=30  total_bytes=None  err=None

  raw.pdl_person: 3 leaves, 30 rows total

For finder mode, file_count, partition_values and row counts reflect what's
actually in S3 (capped by --limit-files).

Re-runs are safe — each invocation generates fresh UUIDs and inserts a new
delivery, so prior runs accumulate. To wipe local state between iterations:

  make dev-reset && make dev-up
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import sys
import uuid
from unittest.mock import MagicMock

import psycopg2

from processing.s3_ingester import file_ingester
from processing.s3_ingester.delivery_loader import load_pending_files
from processing.s3_ingester.finder import discover_delivery


def main() -> int:
    args = _parse_args()
    db_dsn = os.environ.get("DATABASE_URL")
    if not db_dsn:
        sys.stderr.write("error: DATABASE_URL env var is required\n")
        return 2

    if args.mode == "seeded":
        _install_fake_s3()
        ingestion_run_id = _seed_catalog_rows(db_dsn, args.source)
    elif args.mode == "finder":
        ingestion_run_id = _run_finder_then_trim(
            db_dsn=db_dsn,
            source=args.source,
            delivery_date=args.delivery_date,
            limit_files=args.limit_files,
        )
    else:
        raise AssertionError(f"unreachable: mode={args.mode!r}")

    print("\n=== running delivery_loader ===")
    summary = load_pending_files(
        source=args.source,
        ingestion_run_id=ingestion_run_id,
        db_dsn=db_dsn,
        max_concurrency=args.max_concurrency,
    )
    print(json.dumps(summary, indent=2))

    print("\n=== verification ===")
    _print_verification(db_dsn, ingestion_run_id)
    return 0


# -----------------------------------------------------------------------------
# Mode: seeded — hand-seed catalog rows, fake S3
# -----------------------------------------------------------------------------

def _install_fake_s3(rows_per_file: int = 10) -> None:
    """Point file_ingester's boto3 at a fake that serves rows_per_file
    gzipped JSON lines for any key."""
    def _get_object(Bucket, Key):  # noqa: N803 — boto3 kwarg names
        lines = [json.dumps({"id": f"{Key}-fake-{i}"}) for i in range(rows_per_file)]
        stream = MagicMock()
        stream.read.return_value = gzip.compress(("\n".join(lines) + "\n").encode())
        return {"Body": stream}

    client = MagicMock()
    client.get_object.side_effect = _get_object
    file_ingester.boto3.client = lambda *a, **kw: client

def _seed_catalog_rows(db_dsn: str, source: str) -> str:
    """Insert pipeline_run + ingestion_run + 3 ingestion_file rows by hand."""
    pipeline_run_id = uuid.uuid4()
    ingestion_run_id = uuid.uuid4()
    delivery_date = "2026-03-24"  # cosmetic in seeded mode

    print("=== mode: seeded — seeding catalog rows ===")
    print(f"pipeline_run_id  = {pipeline_run_id}")
    print(f"ingestion_run_id = {ingestion_run_id}")

    conn = psycopg2.connect(db_dsn)
    try:
        with conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO catalog.pipeline_run (
                        pipeline_run_id, pipeline_name, pipeline_version,
                        parameters, status, started_at
                    ) VALUES (%s, %s, %s, %s, %s, now())
                    """,
                    (
                        str(pipeline_run_id),
                        f"{source}_load",
                        "smoke-test",
                        "{}",
                        "running",
                    ),
                )
                cur.execute(
                    """
                    INSERT INTO catalog.ingestion_run (
                        ingestion_run_id, pipeline_run_id, source_name,
                        delivery_date, status, started_at
                    ) VALUES (%s, %s, %s, %s, 'started', now())
                    """,
                    (
                        str(ingestion_run_id),
                        str(pipeline_run_id),
                        "pdl_person",
                        delivery_date,
                    ),
                )
                for pv in ("0", "1", "2"):
                    cur.execute(
                        """
                        INSERT INTO catalog.ingestion_file (
                            ingestion_run_id, s3_key, target_table,
                            partition_value, status
                        ) VALUES (%s, %s, %s, %s, 'pending')
                        """,
                        (
                            str(ingestion_run_id),
                            f"{delivery_date.replace('-', '_')}/data/part-0000{pv}.csv.gz",
                            "raw.pdl_person",
                            pv,
                        ),
                    )
    finally:
        conn.close()

    return str(ingestion_run_id)


# -----------------------------------------------------------------------------
# Mode: finder — S3 (MinIO) listing, then trim before loading
# -----------------------------------------------------------------------------

def _run_finder_then_trim(
    *,
    db_dsn: str,
    source: str,
    delivery_date: str,
    limit_files: int,
) -> str:
    """Call Finder against S3 (MinIO), then trim ingestion_file rows to limit_files."""
    print("=== mode: finder — running finder ===")
    print(f"source        = {source}")
    print(f"delivery_date = {delivery_date}")
    print(f"limit_files   = {limit_files}")

    ingestion_run_id = discover_delivery(
        source=source,
        delivery_date=delivery_date,
        db_dsn=db_dsn,
    )
    print(f"ingestion_run_id = {ingestion_run_id}")

    # Trim ingestion_file rows down to limit_files. Keep the first N by
    # ingestion_file_id ordering (stable across runs).
    conn = psycopg2.connect(db_dsn)
    try:
        with conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT count(*) FROM catalog.ingestion_file "
                    "WHERE ingestion_run_id = %s",
                    (ingestion_run_id,),
                )
                row = cur.fetchone()
                assert row is not None
                discovered = row[0]
                cur.execute(
                    """
                    DELETE FROM catalog.ingestion_file
                    WHERE ingestion_run_id = %s
                      AND ingestion_file_id NOT IN (
                          SELECT ingestion_file_id
                          FROM catalog.ingestion_file
                          WHERE ingestion_run_id = %s
                          ORDER BY ingestion_file_id
                          LIMIT %s
                      )
                    """,
                    (ingestion_run_id, ingestion_run_id, limit_files),
                )
                trimmed = cur.rowcount
        print(f"finder discovered {discovered} files; trimmed {trimmed}; "
              f"loading {discovered - trimmed}")
    finally:
        conn.close()

    return ingestion_run_id


# -----------------------------------------------------------------------------
# Verification readout
# -----------------------------------------------------------------------------

def _print_verification(db_dsn: str, ingestion_run_id: str) -> None:
    conn = psycopg2.connect(db_dsn)
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT target_table, partition_value, status, row_count, error_message
                FROM catalog.ingestion_file
                WHERE ingestion_run_id = %s
                ORDER BY target_table, partition_value
                """,
                (ingestion_run_id,),
            )
            print("ingestion_file rows:")
            for tt, pv, status, rc, err in cur.fetchall():
                print(f"  {tt:<30s} pv={pv:<25s} status={status:<8s} "
                      f"row_count={rc!s:<6s} err={err!r}")

            cur.execute(
                """
                SELECT status, total_file_count, total_row_count,
                       total_bytes, error_message
                FROM catalog.ingestion_run
                WHERE ingestion_run_id = %s
                """,
                (ingestion_run_id,),
            )
            row = cur.fetchone()
            assert row is not None
            print(
                f"\ningestion_run: status={row[0]}  "
                f"file_count={row[1]}  total_rows={row[2]}  "
                f"total_bytes={row[3]}  err={row[4]!r}"
            )

            # Per-target-table leaf + row counts (works for whatever raw
            # tables this delivery touched).
            cur.execute(
                """
                SELECT DISTINCT target_table
                FROM catalog.ingestion_file
                WHERE ingestion_run_id = %s
                ORDER BY target_table
                """,
                (ingestion_run_id,),
            )
            target_tables = [r[0] for r in cur.fetchall()]
            print()
            for tt in target_tables:
                schema, table = tt.split(".", 1)
                cur.execute(
                    """
                    SELECT count(*) FROM pg_inherits i
                    JOIN pg_class p ON p.oid = i.inhparent
                    JOIN pg_namespace n ON n.oid = p.relnamespace
                    WHERE p.relname = %s AND n.nspname = %s
                    """,
                    (table, schema),
                )
                leaf_row = cur.fetchone()
                leaves = leaf_row[0] if leaf_row else 0
                cur.execute(f"SELECT count(*) FROM {schema}.{table}")
                rows_row = cur.fetchone()
                rows = rows_row[0] if rows_row else 0
                print(f"{tt}: {leaves} leaves, {rows} rows total")
    finally:
        conn.close()


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Smoke test the S3 Ingester framework against local Postgres.",
    )
    parser.add_argument("--mode", choices=("seeded", "finder"), default="seeded",
                        help="seeded: hand-seed catalog rows (fake S3). "
                             "finder: run Finder against S3 / MinIO.")
    parser.add_argument("--source", default="pdl_full",
                        help="source name; resolves to configs/<source>.yaml")
    parser.add_argument("--delivery-date", default="2026_05_22",
                        help="(finder mode) yyyy_mm_dd PDL delivery prefix")
    parser.add_argument("--limit-files", type=int, default=5,
                        help="(finder mode) trim ingestion_file rows to this many "
                             "before loading; default 5")
    parser.add_argument("--max-concurrency", type=int, default=1,
                        help="Loader max_concurrency (1 = sequential)")
    return parser.parse_args()


if __name__ == "__main__":
    raise SystemExit(main())
