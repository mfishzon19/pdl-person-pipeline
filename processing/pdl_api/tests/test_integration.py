"""Integration tests for the pdl_api company-enrichment pipeline.

These run against a real Postgres with V3 migration applied.
PDL HTTP is still mocked, per CLAUDE.md ("Never call PDL APIs in tests").
Skipped automatically when DATABASE_URL isn't set.

To run locally:

    DATABASE_URL='postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl' \\
        pytest processing/pdl_api/tests/ -m "tier1 and integration"
"""

from __future__ import annotations

import os
import uuid

import psycopg2
import pytest

from processing.pdl_api import company_enrichment as mod

pytestmark = [pytest.mark.tier1, pytest.mark.integration]


# -----------------------------------------------------------------------------
# Fixtures
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


@pytest.fixture
def isolated_source(db_conn):
    """Each test gets a unique `source_list` value so concurrent runs
    and re-runs don't collide on the queue table."""
    src = f"itest-{uuid.uuid4().hex[:8]}"
    yield src
    # Clean up everything tagged with this source.
    with db_conn:
        with db_conn.cursor() as cur:
            cur.execute(
                "DELETE FROM pdl_api.company_enrichment_call WHERE input_list_id IN "
                "(SELECT id FROM pdl_api.company_input_list WHERE source_list = %s)",
                (src,),
            )
            cur.execute(
                "DELETE FROM pdl_api.company_cleaner_call WHERE input_list_id IN "
                "(SELECT id FROM pdl_api.company_input_list WHERE source_list = %s)",
                (src,),
            )
            cur.execute(
                "DELETE FROM pdl_api.company_input_list WHERE source_list = %s",
                (src,),
            )


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

def _seed(conn, source_list, rows):
    """Seed N rows into company_input_list. Each row is a dict with
    `pdl_search_params` (jsonb) and optional `pdl_company_id`."""
    ids = []
    with conn:
        with conn.cursor() as cur:
            for row in rows:
                cur.execute(
                    """
                    INSERT INTO pdl_api.company_input_list (
                        source_list, pdl_search_params, pdl_company_id,
                        cleaner_status, enrichment_status
                    ) VALUES (%s, %s::jsonb, %s, %s, 'pending')
                    RETURNING id
                    """,
                    (
                        source_list,
                        row["pdl_search_params"],
                        row.get("pdl_company_id"),
                        "not_needed" if row.get("pdl_company_id") else "pending",
                    ),
                )
                ids.append(cur.fetchone()[0])
    return ids


def _fetch_row(conn, input_list_id):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT cleaner_status, enrichment_status, pdl_company_id, "
            "worker_id, claimed_at FROM pdl_api.company_input_list WHERE id = %s",
            (input_list_id,),
        )
        return cur.fetchone()


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

def test_cleaner_pass_resolves_id_and_audits_call(
    mocker, db_conn, db_dsn, isolated_source,
):
    """Cleaner returns 200 with an id. The queue row should land at
    `resolved`, `pdl_company_id` populated, and one audit row should
    exist with the generated `pdl_company_id` column also populated."""
    [row_id] = _seed(db_conn, isolated_source, [
        {"pdl_search_params": '{"name": "Acme Corp"}'},
    ])
    mocker.patch("processing.common.pdl.client.pdl_api_call", return_value={
        "http_status": 200,
        "body": {"id": "fake-pdl-id-123", "name": "acme corp"},
        "latency_ms": 42,
        "error_message": None, "retry_after": None,
    })

    n = mod.process_cleaner_batch(db_conn, "test-worker")
    assert n == 1

    cleaner_status, enrichment_status, pdl_id, worker, claimed = _fetch_row(db_conn, row_id)
    assert cleaner_status == "resolved"
    assert enrichment_status == "pending"
    assert pdl_id == "fake-pdl-id-123"
    assert worker is None
    assert claimed is None

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT response_status, pdl_company_id, latency_ms "
            "FROM pdl_api.company_cleaner_call WHERE input_list_id = %s",
            (row_id,),
        )
        assert cur.fetchone() == (200, "fake-pdl-id-123", 42)


def test_cleaner_404_marks_not_found_and_skips_enrichment_view(
    mocker, db_conn, db_dsn, isolated_source,
):
    """Cleaner returns 404. Queue row → not_found, pdl_company_id stays
    NULL, and the enrichment view does not surface it (no pdl_company_id
    to enrich)."""
    [row_id] = _seed(db_conn, isolated_source, [
        {"pdl_search_params": '{"name": "Made Up Co"}'},
    ])
    mocker.patch("processing.common.pdl.client.pdl_api_call", return_value={
        "http_status": 404, "body": {"error": "no match"},
        "latency_ms": 30, "error_message": None, "retry_after": None,
    })

    mod.process_cleaner_batch(db_conn, "test-worker")

    cleaner_status, _, pdl_id, _, _ = _fetch_row(db_conn, row_id)
    assert cleaner_status == "not_found"
    assert pdl_id is None

    # Enrichment view should ignore the row (no resolved pdl_company_id).
    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) FROM pdl_api.v_company_input_for_enrichment "
            "WHERE input_list_id = %s",
            (row_id,),
        )
        assert cur.fetchone()[0] == 0


def test_enrichment_bulk_audits_per_record_with_generated_columns(
    mocker, db_conn, db_dsn, isolated_source,
):
    """Two pre-resolved rows go through one bulk call. We get two audit
    rows sharing the same bulk_batch_id, generated columns populated
    from response_json (pdl_company_id, pdl_dataset_version,
    pdl_likelihood), and both queue rows end at `enriched`."""
    [id_a, id_b] = _seed(db_conn, isolated_source, [
        {"pdl_search_params": '{"id": "A"}', "pdl_company_id": "A"},
        {"pdl_search_params": '{"id": "B"}', "pdl_company_id": "B"},
    ])

    def fake_bulk(endpoint, payload):
        assert endpoint == "/v5/company/enrich/bulk"
        # PDL echoes back the metadata.input_list_id so we can correlate.
        items = []
        for r in payload["requests"]:
            pid = r["params"]["pdl_id"]
            items.append({
                "status": 200,
                "id": pid,
                "dataset_version": "34.0",
                "likelihood": 10,
                "metadata": r["metadata"],
            })
        return {"http_status": 200, "body": items,
                "latency_ms": 77, "error_message": None, "retry_after": None}

    mocker.patch("processing.common.pdl.client.pdl_api_call", side_effect=fake_bulk)

    mod.process_enrichment_batch(db_conn, "test-worker")

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT input_list_id, response_status, pdl_company_id, "
            "pdl_dataset_version, pdl_likelihood, bulk_batch_id "
            "FROM pdl_api.company_enrichment_call "
            "WHERE input_list_id IN (%s, %s) ORDER BY input_list_id",
            (id_a, id_b),
        )
        rows = cur.fetchall()

    assert len(rows) == 2
    assert rows[0][0] == id_a and rows[0][1] == 200 and rows[0][2] == "A"
    assert rows[1][0] == id_b and rows[1][1] == 200 and rows[1][2] == "B"
    # Generated columns auto-populated.
    assert rows[0][3] == "34.0" and rows[0][4] == 10
    assert rows[1][3] == "34.0" and rows[1][4] == 10
    # Both audit rows share the same bulk_batch_id.
    assert rows[0][5] == rows[1][5]

    assert _fetch_row(db_conn, id_a)[1] == "enriched"
    assert _fetch_row(db_conn, id_b)[1] == "enriched"


def test_sibling_skip_marks_duplicates_already_enriched(
    mocker, db_conn, db_dsn, isolated_source,
):
    """Two queue rows with the same pdl_company_id (e.g. two source lists
    both include company X). The first to make it through enrichment flips the
    other one to skipped_already_enriched."""
    [first, second] = _seed(db_conn, isolated_source, [
        {"pdl_search_params": '{"id": "X"}', "pdl_company_id": "X"},
        {"pdl_search_params": '{"id": "X"}', "pdl_company_id": "X"},
    ])

    def fake_bulk(endpoint, payload):
        # Only the first id will be in the payload because limit=1 below.
        items = [{
            "status": 200, "id": r["params"]["pdl_id"],
            "dataset_version": "34.0", "likelihood": 10,
            "metadata": r["metadata"],
        } for r in payload["requests"]]
        return {"http_status": 200, "body": items,
                "latency_ms": 30, "error_message": None, "retry_after": None}

    mocker.patch("processing.common.pdl.client.pdl_api_call", side_effect=fake_bulk)

    # Force a single-row batch so the second row is left to get skipped.
    mod.process_enrichment_batch(db_conn, "test-worker", limit=1)

    assert _fetch_row(db_conn, first)[1] == "enriched"
    assert _fetch_row(db_conn, second)[1] == "skipped_already_enriched"


def test_pre_resolved_row_bypasses_cleaner_view(
    db_conn, db_dsn, isolated_source,
):
    """A row that arrives with `pdl_company_id` already set + status
    `not_needed` should not surface in the cleaner view, but should
    surface in the enrichment view."""
    [row_id] = _seed(db_conn, isolated_source, [
        {"pdl_search_params": '{"id": "Y"}', "pdl_company_id": "Y"},
    ])

    with db_conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) FROM pdl_api.v_company_input_for_cleaner "
            "WHERE input_list_id = %s", (row_id,),
        )
        assert cur.fetchone()[0] == 0

        cur.execute(
            "SELECT count(*) FROM pdl_api.v_company_input_for_enrichment "
            "WHERE input_list_id = %s", (row_id,),
        )
        assert cur.fetchone()[0] == 1
