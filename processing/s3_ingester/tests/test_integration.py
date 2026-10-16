"""Tier 1 integration tests for the s3_ingester package.

Two tests, both marked `tier1` and `integration`. They run against a
real local Postgres (the docker-compose one, after flyway-init). S3 is
faked: `file_ingester.boto3.client` is patched to serve a gzipped
10-row PDL-shaped file for every key, so no MinIO is needed. They skip
on their own when DATABASE_URL isn't set (see conftest.py).

  1. End-to-end happy path. We hand-seed a `pipeline_run`, an
     `ingestion_run`, and 3 pending `ingestion_file` rows, run
     `load_pending_files`, and check that all three files reach
     'success' with 10 rows each (the fake file's size), and the
     ingestion_run lands at 'success' with the right totals.
  2. `replace_strategy: full` wipes stale data between deliveries.
     Run delivery A with partition_values {0, 1, 2}, then delivery B
     with {0, 1}. Delivery A's third leaf should be empty after
     delivery B, because pdl_full.yaml's `replace_strategy: full`
     TRUNCATEs the parent at the start of each load.

To run locally:

    make dev-up      # postgres + flyway-init (schema applied)
    DATABASE_URL='postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl' \\
         pytest processing/s3_ingester/tests/ -m "tier1 and integration"

Re-run, mid-load failure, and other end-to-end variants live in
Tier 2 (see docs/design/07_test_plan.md).
"""

from __future__ import annotations

import gzip
import json
import os
import uuid
from unittest.mock import MagicMock

import psycopg2
import pytest

from processing.s3_ingester import file_ingester
from processing.s3_ingester.delivery_loader import load_pending_files

pytestmark = [pytest.mark.tier1, pytest.mark.integration]

# Rows per fake S3 object. Every seeded file loads exactly this many.
_ROWS_PER_FILE = 10


@pytest.fixture(autouse=True)
def fake_s3(monkeypatch):
    """Serve a gzipped _ROWS_PER_FILE-line JSONL body for any S3 key.

    Lines are plain JSON; pdl_full's COPY options use \x01 / \x02 as
    delimiter / quote, so each line lands whole in the `payload` column.
    """
    def _get_object(Bucket, Key):  # noqa: N803 — boto3 kwarg names
        lines = [json.dumps({"id": f"{Key}-fake-{i}"}) for i in range(_ROWS_PER_FILE)]
        body = gzip.compress(("\n".join(lines) + "\n").encode())
        stream = MagicMock()
        stream.read.return_value = body
        return {"Body": stream}

    client = MagicMock()
    client.get_object.side_effect = _get_object
    monkeypatch.setattr(file_ingester.boto3, "client", lambda *a, **kw: client)
    return client


# -----------------------------------------------------------------------------
# Fixtures and seeding helpers
# -----------------------------------------------------------------------------

@pytest.fixture
def db_dsn():
    dsn = os.environ.get("DATABASE_URL")
    assert dsn, "DATABASE_URL must be set for integration tests"
    return dsn


@pytest.fixture
def db_conn(db_dsn):
    conn = psycopg2.connect(db_dsn)
    try:
        yield conn
    finally:
        conn.close()


def _seed_pipeline_run(conn) -> str:
    pipeline_run_id = str(uuid.uuid4())
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
                    pipeline_run_id,
                    "pdl_full_load",
                    "integration-test",
                    "{}",
                    "running",
                ),
            )
    return pipeline_run_id


def _seed_ingestion_run(conn, pipeline_run_id: str) -> str:
    ingestion_run_id = str(uuid.uuid4())
    with conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO catalog.ingestion_run (
                    ingestion_run_id, pipeline_run_id, source_name,
                    delivery_date, status, started_at
                ) VALUES (%s, %s, 'pdl_person', %s, 'started', now())
                """,
                (ingestion_run_id, pipeline_run_id, "2026-03-24"),
            )
    return ingestion_run_id


def _seed_pending_files(conn, ingestion_run_id: str, partition_values: list[str]) -> list[str]:
    file_ids = []
    with conn:
        with conn.cursor() as cur:
            for pv in partition_values:
                fid = str(uuid.uuid4())
                cur.execute(
                    """
                    INSERT INTO catalog.ingestion_file (
                        ingestion_file_id, ingestion_run_id, s3_key,
                        target_table, partition_value, status
                    ) VALUES (%s, %s, %s, 'raw.pdl_person', %s, 'pending')
                    """,
                    (fid, ingestion_run_id, f"test/part-{pv}.csv.gz", pv),
                )
                file_ids.append(fid)
    return file_ids


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

def test_end_to_end_happy_path(db_conn, db_dsn):
    """The smoke test, but as pytest with proper assertions. Three
    seeded files all reach 'success' with 10 rows each, and the
    ingestion_run lands at 'success' with file_count=3, total_rows=30."""
    pipeline_run_id = _seed_pipeline_run(db_conn)
    ingestion_run_id = _seed_ingestion_run(db_conn, pipeline_run_id)
    # Use a partition value range that's unlikely to clash with other tests.
    base = 900 + (uuid.uuid4().int % 90)
    pvs = [str(base + i) for i in range(3)]
    file_ids = _seed_pending_files(db_conn, ingestion_run_id, pvs)

    summary = load_pending_files(
        source="pdl_full",
        ingestion_run_id=ingestion_run_id,
        db_dsn=db_dsn,
        max_concurrency=1,
    )

    assert summary["succeeded"] is True
    assert summary["file_count"] == 3
    assert summary["total_row_count"] == 30

    with db_conn.cursor() as cur:
        for fid in file_ids:
            cur.execute(
                "SELECT status, row_count FROM catalog.ingestion_file "
                "WHERE ingestion_file_id = %s",
                (fid,),
            )
            status, row_count = cur.fetchone()
            assert status == "success"
            assert row_count == 10

        cur.execute(
            "SELECT status, total_file_count, total_row_count "
            "FROM catalog.ingestion_run WHERE ingestion_run_id = %s",
            (ingestion_run_id,),
        )
        status, file_count, total_rows = cur.fetchone()
        assert status == "success"
        assert file_count == 3
        assert total_rows == 30


def test_replace_strategy_full_wipes_stale_data(db_conn, db_dsn):
    """Two deliveries, same source, same parent table. Delivery A has
    3 partition_values, delivery B has 2 (a subset). Because
    pdl_full.yaml uses `replace_strategy: full`, the parent gets
    TRUNCATEd at the start of B, so A's third leaf ends up empty.
    Without this, stale rows would linger under partition_values that
    weren't in the latest delivery."""
    pipeline_run_id = _seed_pipeline_run(db_conn)

    base = 700 + (uuid.uuid4().int % 90)
    pvs_a = [str(base), str(base + 1), str(base + 2)]
    pvs_b = [str(base), str(base + 1)]

    # Delivery A: 3 files.
    run_a = _seed_ingestion_run(db_conn, pipeline_run_id)
    _seed_pending_files(db_conn, run_a, pvs_a)
    load_pending_files(
        source="pdl_full", ingestion_run_id=run_a,
        db_dsn=db_dsn, max_concurrency=1,
    )

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) FROM raw.pdl_person "
            "WHERE partition_id IN %s",
            (tuple(int(p) for p in pvs_a),),
        )
        (count_after_a,) = cur.fetchone()
        assert count_after_a == 30

    # Delivery B: 2 files. Same source config, so the parent gets
    # TRUNCATEd before this load.
    run_b = _seed_ingestion_run(db_conn, pipeline_run_id)
    _seed_pending_files(db_conn, run_b, pvs_b)
    load_pending_files(
        source="pdl_full", ingestion_run_id=run_b,
        db_dsn=db_dsn, max_concurrency=1,
    )

    with db_conn.cursor() as cur:
        # Total under all three of A's leaves should now be 20 (just B's
        # two files at 10 fake rows each).
        cur.execute(
            "SELECT count(*) FROM raw.pdl_person "
            "WHERE partition_id IN %s",
            (tuple(int(p) for p in pvs_a),),
        )
        (count_after_b,) = cur.fetchone()
        assert count_after_b == 20

        # And A's third leaf should be completely empty.
        cur.execute(
            "SELECT count(*) FROM raw.pdl_person WHERE partition_id = %s",
            (int(pvs_a[2]),),
        )
        (orphan_rows,) = cur.fetchone()
        assert orphan_rows == 0
