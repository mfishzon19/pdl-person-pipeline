"""Tier 1 unit tests for delivery_loader.py.

Eight tests, all marked `tier1`:

  1. `_load_source_config` accepts `replace_strategy: full` and
     `per_partition`, and returns a dict when the key is missing
     (parametrized over the three cases).
  2. `_load_source_config` rejects an unknown `replace_strategy` value.
  3. `_load_source_config` raises and names the missing key when
     `column_list` is absent from the YAML.
  4. `load_pending_files` with no pending rows: it marks the run
     'failed', raises RuntimeError, and never calls ingest_file.
  5. `load_pending_files` with `replace_strategy: full` calls
     `_truncate_target_tables` once before the per-file loop. With
     `per_partition` or no key, it skips the truncate.
  6. `load_pending_files` sequential, 2nd of 3 files fails: the loop
     bails after 2 calls, the run is marked 'failed', and the
     exception is re-raised.
  7. `load_pending_files` concurrent, one file fails: the run still
     ends 'failed' and the exception is re-raised. We don't pin the
     ingest call count because the thread pool may submit more files
     before noticing the failure.
  8. `_truncate_target_tables` also empties config file groups that have
     no files in this delivery (stale-delta regression).

CLI tests, aggregate corner cases, and `_load_one` dispatch live in
Tier 2 (see docs/design/07_test_plan.md).
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from processing.s3_ingester import delivery_loader
from processing.s3_ingester.delivery_loader import (
    _load_source_config,
    load_pending_files,
)

# -----------------------------------------------------------------------------
# _load_source_config
# -----------------------------------------------------------------------------

@pytest.mark.tier1
@pytest.mark.parametrize(
    "fixture_name, expected_strategy",
    [
        ("source_partitioned", "full"),
        ("source_per_partition", "per_partition"),
        ("source_flat", None),  # key absent, defaults at the consumer side
    ],
    ids=["full", "per_partition", "default_absent"],
)
def test_load_source_config_accepts_replace_strategy(
    configs_dir, fixture_name, expected_strategy,
):
    """All three valid shapes load. A missing key is fine, the loader
    treats it as the default."""
    config = _load_source_config(fixture_name)
    assert isinstance(config, dict)
    assert config.get("replace_strategy") == expected_strategy


@pytest.mark.tier1
def test_load_source_config_rejects_invalid_replace_strategy(configs_dir):
    """Anything outside `full` or `per_partition` should raise. Stops a
    config typo from making it to production silently."""
    with pytest.raises(ValueError, match="replace_strategy must be one of"):
        _load_source_config("source_invalid_replace")


@pytest.mark.tier1
def test_load_source_config_missing_column_list_lists_key(configs_dir):
    """The error needs to name the missing key so the dev knows what to
    add."""
    with pytest.raises(ValueError, match="missing required keys") as excinfo:
        _load_source_config("source_missing_column_list")
    assert "column_list" in str(excinfo.value)


# -----------------------------------------------------------------------------
# load_pending_files
# -----------------------------------------------------------------------------

def _patch_loader(mocker, mock_conn, pending, aggregate=(3, 30, 1024),
                  ingest_side_effect=None):
    """Stand in for the four collaborators load_pending_files reaches into.

    Pass `ingest_side_effect` (a list) to make ingest_file return or
    raise a different value per call.
    """
    mocker.patch.object(delivery_loader, "connect", return_value=mock_conn)
    mocker.patch.object(delivery_loader, "_select_pending_files",
                        return_value=pending)
    mocker.patch.object(delivery_loader, "_aggregate_from_files",
                        return_value=aggregate)
    finalize = mocker.patch.object(delivery_loader, "_finalize_run")
    if ingest_side_effect is not None:
        ingest = mocker.patch.object(delivery_loader, "ingest_file",
                                     side_effect=ingest_side_effect)
    else:
        ingest = mocker.patch.object(delivery_loader, "ingest_file",
                                     return_value=10)
    truncate = mocker.patch.object(delivery_loader, "_truncate_target_tables")
    return ingest, finalize, truncate


def _three_pending():
    """Three pending file rows for the mid-stream-failure tests."""
    return [
        {
            "ingestion_file_id": f"uuid-{i}",
            "target_table": "raw.pdl_person",
            "s3_key": f"data/part-0000{i}.csv.gz",
            "partition_value": str(i),
        }
        for i in range(3)
    ]


@pytest.mark.tier1
def test_load_pending_files_empty_list_marks_failed_and_raises(
    mocker, mock_conn, configs_dir,
):
    """No pending rows means Finder didn't write any. Treat it as a bug,
    mark the run failed, raise, and never touch ingest_file."""
    ingest, finalize, _ = _patch_loader(mocker, mock_conn, pending=[])

    with pytest.raises(RuntimeError, match="no pending"):
        load_pending_files(
            source="source_partitioned",
            ingestion_run_id="run-uuid",
            db_dsn="postgresql://fake",
        )

    ingest.assert_not_called()
    finalize.assert_called_once()
    assert finalize.call_args.kwargs["status"] == "failed"


@pytest.mark.tier1
@pytest.mark.parametrize(
    "source_fixture, expect_truncate",
    [
        ("source_partitioned", True),     # replace_strategy: full
        ("source_per_partition", False),  # replace_strategy: per_partition
        ("source_flat", False),           # key absent, treated as per_partition
    ],
    ids=["full_truncates", "per_partition_skips", "absent_skips"],
)
def test_load_pending_files_truncate_only_for_full_strategy(
    mocker, mock_conn, configs_dir, source_fixture, expect_truncate,
):
    """`replace_strategy: full` means TRUNCATE the parent table once
    before the per-file loop. The other two strategies don't."""
    pending = [
        {
            "ingestion_file_id": "uuid-1",
            "target_table": "raw.pdl_person",
            "s3_key": "data/part-00001.csv.gz",
            "partition_value": "1",
        },
    ]
    ingest, _, truncate = _patch_loader(mocker, mock_conn, pending)

    # Attach both to a parent so we can verify call order, not just
    # that each was called the right number of times.
    manager = MagicMock()
    manager.attach_mock(truncate, "truncate")
    manager.attach_mock(ingest, "ingest")

    load_pending_files(
        source=source_fixture,
        ingestion_run_id="run-uuid",
        db_dsn="postgresql://fake",
        max_concurrency=1,
    )

    if expect_truncate:
        truncate.assert_called_once()
        # Called with (conn, files, config). The files list should match
        # what _select_pending_files gave back.
        assert truncate.call_args.args[1] == pending
        # And truncate must run before the per-file loop, otherwise the
        # parent could keep stale rows that ingest_file's per-leaf
        # TRUNCATE wouldn't catch.
        call_order = [c[0] for c in manager.mock_calls]
        assert call_order[0] == "truncate"
    else:
        truncate.assert_not_called()


@pytest.mark.tier1
def test_load_pending_files_second_file_fails_sequential(
    mocker, mock_conn, configs_dir,
):
    """Sequential mode. The 2nd of 3 files raises. The loop bails before
    file 3, the run is marked 'failed' with the error message, and the
    original exception is re-raised."""
    pending = _three_pending()
    boom = RuntimeError("file 2 blew up")
    ingest, finalize, _ = _patch_loader(
        mocker, mock_conn, pending,
        ingest_side_effect=[10, boom, 10],
    )

    with pytest.raises(RuntimeError, match="file 2 blew up"):
        load_pending_files(
            source="source_partitioned",
            ingestion_run_id="run-uuid",
            db_dsn="postgresql://fake",
            max_concurrency=1,
        )

    assert ingest.call_count == 2
    finalize.assert_called_once()
    assert finalize.call_args.kwargs["status"] == "failed"
    assert "file 2 blew up" in finalize.call_args.kwargs["error_message"]


@pytest.mark.tier1
def test_load_pending_files_second_file_fails_concurrent(
    mocker, mock_conn, configs_dir,
):
    """Concurrent mode. One file raises. The run still ends 'failed' and
    the exception is re-raised. We don't check the call count because
    the thread pool may have submitted other files before noticing."""
    pending = _three_pending()
    boom = RuntimeError("file 2 blew up")
    _, finalize, _ = _patch_loader(
        mocker, mock_conn, pending,
        ingest_side_effect=[10, boom, 10],
    )

    with pytest.raises(RuntimeError, match="file 2 blew up"):
        load_pending_files(
            source="source_partitioned",
            ingestion_run_id="run-uuid",
            db_dsn="postgresql://fake",
            max_concurrency=3,
        )

    finalize.assert_called_once()
    assert finalize.call_args.kwargs["status"] == "failed"


# -----------------------------------------------------------------------------
# _truncate_target_tables
# -----------------------------------------------------------------------------

@pytest.mark.tier1
def test_truncate_includes_config_file_groups_without_files(mock_conn, mock_cursor):
    """Optional file groups with no files this delivery are still emptied.

    Regression: only tables with files used to be truncated, so a delivery
    without DELETED_RECORDS left the previous delivery's rows in
    raw.pdl_deleted_records, and raw.project_pdl_deltas() re-projected them
    under the new delivery date."""
    files = [{"target_table": "raw.pdl_person"}]
    config = {
        "file_groups": [
            {"name": "pdl_data", "target_table": "raw.pdl_person"},
            {"name": "pdl_deleted", "target_table": "raw.pdl_deleted_records"},
        ],
    }

    delivery_loader._truncate_target_tables(mock_conn, files, config)

    truncated = [repr(c.args[0]) for c in mock_cursor.execute.call_args_list]
    assert len(truncated) == 2  # each table once, despite pdl_person appearing twice
    assert any("'pdl_deleted_records'" in t for t in truncated)
    assert any("'pdl_person'" in t for t in truncated)
