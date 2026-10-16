"""Tier 1 unit tests for finder.py.

Four tests, all marked `tier1`:

  1. `discover_delivery` rejects a hyphenated `delivery_date`. Locks in
     the regression for the str.format() vs `\\d{5}` bug.
  2. `_discover_files` honours required vs optional `file_groups`. A
     required group with zero matches raises. An optional group with
     zero matches returns silently.
  3. `_write_catalog_rows` INSERTs exactly one `pipeline_run` row with
     a DB-assigned id and threads that id into `ingestion_run`.
  4. `_insert_pdl_delivery` parses `pdl_dataset_id` from a
     `MONTHLY_V_NN.N` substring in the discovered keys, falling back
     to `'unknown'` when no key has it.

The wider config-validation matrix and S3-error branching tests
are deferred to Tier 2 (see docs/design/07_test_plan.md).
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from processing.s3_ingester import finder
from processing.s3_ingester.finder import (
    _discover_files,
    _insert_pdl_delivery,
    _write_catalog_rows,
    discover_delivery,
)

# -----------------------------------------------------------------------------
# discover_delivery: delivery_date format guard
# -----------------------------------------------------------------------------

@pytest.mark.tier1
def test_discover_delivery_rejects_hyphenated_date():
    """Reject `2026-03-24`. PDL S3 keys use the `2026_03_24` shape, and
    the `{delivery_date}` substitution into regex patterns depends on
    that exact form. Also the regression test for the str.format() vs
    `\\d{5}` bug."""
    with pytest.raises(ValueError, match="delivery_date must be 'yyyy_mm_dd'"):
        discover_delivery(
            source="pdl_full",
            delivery_date="2026-03-24",
            db_dsn="postgresql://fake",
        )


# -----------------------------------------------------------------------------
# _discover_files: required vs optional file_groups
# -----------------------------------------------------------------------------

def _make_paginator(pages_by_prefix: dict[str, list[dict]]):
    """Build a mock S3 client that returns different objects per prefix.

    Each entry in a page is a dict shaped like a real S3 object
    (`{"Key": ..., "Size": ...}`).
    """
    s3 = MagicMock()
    paginator = MagicMock()

    def paginate(Bucket, Prefix):  # noqa: N803 (mirrors boto3 kwargs)
        return [{"Contents": pages_by_prefix.get(Prefix, [])}]

    paginator.paginate.side_effect = paginate
    s3.get_paginator.return_value = paginator
    return s3


@pytest.mark.tier1
def test_discover_files_required_empty_raises():
    """A required file_group with zero matches must raise. Otherwise
    we'd quietly load a delivery that's missing its main batch."""
    s3 = _make_paginator({"2026_03_24/data/": []})
    file_groups = [{
        "name": "pdl_data",
        "s3_list_prefix": "{delivery_date}/data/",
        "key_pattern": r"^{delivery_date}/data/part-(?P<partition_id>\d{5})\.csv\.gz$",
        "target_table": "raw.pdl_person",
        "partition_value_from": "partition_id",
        "optional": False,
    }]

    with pytest.raises(RuntimeError, match="required file_group .* matched no files"):
        _discover_files(s3, "test-bucket", file_groups, "2026_03_24")


@pytest.mark.tier1
def test_discover_files_optional_empty_skips():
    """An optional file_group with zero matches must NOT raise. First
    deliveries without delta_data should still succeed."""
    s3 = _make_paginator({"2026_03_24/delta_data/": []})
    file_groups = [{
        "name": "pdl_merged",
        "s3_list_prefix": "{delivery_date}/delta_data/",
        "key_pattern": r"^{delivery_date}/delta_data/MERGED.*$",
        "target_table": "raw.pdl_merged_records",
        "partition_value_from": "partition_id",
        "optional": True,
    }]

    result = _discover_files(s3, "test-bucket", file_groups, "2026_03_24")
    assert result == []


# -----------------------------------------------------------------------------
# _write_catalog_rows: pipeline_run parent row
# -----------------------------------------------------------------------------

def _make_db_conn(returning_uuids: list[str]):
    """Mock a psycopg2 connection that supports `with conn:` and feeds
    UUIDs back from RETURNING clauses (for `pipeline_run_id` and
    `ingestion_run_id`)."""
    conn = MagicMock(name="connection")
    conn.__enter__ = MagicMock(return_value=conn)
    conn.__exit__ = MagicMock(return_value=None)
    cur = MagicMock(name="cursor")
    cur.__enter__ = MagicMock(return_value=cur)
    cur.__exit__ = MagicMock(return_value=None)
    cur.fetchone.side_effect = [(u,) for u in returning_uuids]
    conn.cursor.return_value = cur
    return conn, cur


@pytest.mark.tier1
def test_write_catalog_rows_inserts_pipeline_run(mocker):
    """Finder INSERTs one pipeline_run row; the DB assigns the id via
    DEFAULT gen_random_uuid() and we capture it via RETURNING. The
    downstream INSERT INTO catalog.ingestion_run carries a FK to
    pipeline_run.pipeline_run_id, so it must use that returned id."""
    # Two RETURNING clauses fire: pipeline_run, then ingestion_run.
    returning = ["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                 "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"]
    conn, cur = _make_db_conn(returning)
    mocker.patch.object(finder, "connect", return_value=conn)

    files_to_load = [{
        "target_table": "raw.pdl_person",
        "s3_key": "2026_03_24/data/part-00001.csv.gz",
        "partition_value": "1",
        "size_bytes": 100,
    }]
    file_groups = [{"name": "pdl_data", "target_table": "raw.pdl_person"}]

    ingestion_run_id = _write_catalog_rows(
        db_dsn="postgresql://fake",
        source="pdl_full",
        delivery_date="2026_03_24",
        files_to_load=files_to_load,
        file_groups=file_groups,
        pipeline_version="local",
    )
    assert ingestion_run_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    calls = cur.execute.call_args_list
    pipeline_inserts = [c for c in calls if "INSERT INTO catalog.pipeline_run" in c.args[0]]
    assert len(pipeline_inserts) == 1, (
        f"expected exactly one pipeline_run INSERT; got {len(pipeline_inserts)}"
    )
    sql_text, _ = pipeline_inserts[0].args
    assert "RETURNING pipeline_run_id" in sql_text

    run_inserts = [c for c in calls if "INSERT INTO catalog.ingestion_run" in c.args[0]]
    assert len(run_inserts) == 1
    _, run_params = run_inserts[0].args
    assert run_params[0] == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

# -----------------------------------------------------------------------------
# _insert_pdl_delivery: pdl_dataset_id parsing
# -----------------------------------------------------------------------------

@pytest.mark.tier1
@pytest.mark.parametrize(
    "s3_keys, expected_dataset_id",
    [
        (
            [
                "2026_03_24/data/part-00001.csv.gz",
                "2026_03_24/delta_data/MERGED_RECORDS_MONTHLY_V_34.0/part-00001.gz",
            ],
            "34.0",
        ),
        (
            ["2026_03_24/data/part-00001.csv.gz"],
            "unknown",
        ),
    ],
    ids=["with_monthly_v", "data_only_falls_back"],
)
def test_insert_pdl_delivery_dataset_id_parsing(s3_keys, expected_dataset_id):
    """`pdl_dataset_id` comes from the `MONTHLY_V_NN.N` substring in
    any discovered key. First deliveries (no delta_data) have no such
    substring, so we fall back to `'unknown'`."""
    cur = MagicMock()
    files_to_load = [
        {"target_table": "raw.pdl_person", "s3_key": k, "partition_value": "1",
         "size_bytes": 1}
        for k in s3_keys
    ]
    file_groups = [{"name": "pdl_data", "target_table": "raw.pdl_person"}]

    _insert_pdl_delivery(
        cur,
        iso_delivery_date="2026-03-24",
        files_to_load=files_to_load,
        file_groups=file_groups,
    )

    cur.execute.assert_called_once()
    sql_text, params = cur.execute.call_args.args
    assert "INSERT INTO catalog.pdl_delivery" in sql_text
    # params layout: (iso_delivery_date, pdl_dataset_id, file_counts_json)
    assert params[1] == expected_dataset_id
