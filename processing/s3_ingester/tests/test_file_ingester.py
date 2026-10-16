"""Tier 1 unit tests for file_ingester.py.

Three tests, all marked `tier1`:

  1. `_validate_partition_args` returns either a 3-tuple or None,
     depending on which partition args were supplied. Parametrized over
     the four cases.
  2. `_run_with_catalog_lifecycle` happy path: when the load action
     returns a row count, tx1 marks the file 'loading', tx2 marks it
     'success' with that row count, the helper returns the row count.
  3. `_run_with_catalog_lifecycle` failure path: when the load action
     raises, tx1 marks 'loading', tx2 rolls back, tx3 marks 'failed'
     with the error message, and the original exception bubbles up.
     This is the trickiest code in the package.

CLI argparse tests, the `_typed_literal` type fan-out, and DDL emission
checks are deferred to Tier 2 (see docs/design/07_test_plan.md).
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from processing.s3_ingester.file_ingester import (
    _run_with_catalog_lifecycle,
    _validate_partition_args,
)


@pytest.mark.tier1
@pytest.mark.parametrize(
    "args, expected",
    [
        ((None, None, None), None),
        (("partition_id", "86", "smallint"), ("partition_id", "86", "smallint")),
        (("partition_id", None, None), ValueError),
        ((None, None, "smallint"), ValueError),
    ],
    ids=["all_none", "all_set", "only_column", "only_value_type"],
)
def test_validate_partition_args(args, expected):
    """All-or-nothing rule. Either supply all three partition args or none."""
    if expected is ValueError:
        with pytest.raises(ValueError, match="must all be set together"):
            _validate_partition_args(*args)
    else:
        assert _validate_partition_args(*args) == expected


@pytest.mark.tier1
def test_run_with_catalog_lifecycle_success_path(mock_conn, mock_cursor):
    """Happy path. The load action returns (imported, actual) = (42, 42),
    so we expect tx1 to mark the file 'loading' and tx2 to mark it
    'success' with expected_row_count=42 + row_count=42. The helper
    returns the actual count."""
    load_action = MagicMock(return_value=(42, 42))

    result = _run_with_catalog_lifecycle(
        mock_conn, "ingestion-file-uuid", load_action,
    )

    assert result == 42
    # Two `with conn:` blocks on the happy path: tx1 + tx2.
    assert mock_conn.__enter__.call_count == 2
    load_action.assert_called_once_with(mock_cursor)

    # Two UPDATE statements run: tx1 sets 'loading', tx2 sets 'success'.
    # The action itself is mocked, so it adds nothing of its own.
    executes = mock_cursor.execute.call_args_list
    assert len(executes) == 2
    tx1_sql, tx1_params = executes[0].args
    tx2_sql, tx2_params = executes[1].args
    assert "status='loading'" in tx1_sql
    assert tx1_params == ("ingestion-file-uuid",)
    assert "status='success'" in tx2_sql
    assert "expected_row_count" in tx2_sql
    assert "row_count" in tx2_sql
    assert tx2_params == (42, 42, "ingestion-file-uuid")


@pytest.mark.tier1
def test_run_with_catalog_lifecycle_failure_path(mock_conn, mock_cursor):
    """Failure path. The load action raises, so the helper should mark
    the file 'loading' in tx1, roll back tx2, mark it 'failed' in tx3
    with the error message, and re-raise the original exception. This
    path keeps a failed file from being left in 'loading' forever."""
    load_action = MagicMock(side_effect=RuntimeError("copy blew up"))

    with pytest.raises(RuntimeError, match="copy blew up"):
        _run_with_catalog_lifecycle(mock_conn, "ingestion-file-uuid", load_action)

    # Three `with conn:` blocks open: tx1, tx2 (which raises), tx3.
    assert mock_conn.__enter__.call_count == 3

    # Two UPDATE statements run: tx1 sets 'loading', tx3 sets 'failed'.
    # tx2's success UPDATE never runs because the action raised first.
    executes = mock_cursor.execute.call_args_list
    assert len(executes) == 2
    tx1_sql, _ = executes[0].args
    tx3_sql, tx3_params = executes[1].args
    assert "status='loading'" in tx1_sql
    assert "status='failed'" in tx3_sql
    assert tx3_params == ("copy blew up", "ingestion-file-uuid")
