"""Unit tests for processing.common.db.batch.

psycopg2 + execute_values mocked; no live DB.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import psycopg2
import pytest

from processing.common.db import (
    IntegrityError,
    QueryError,
    TransientError,
    batch_insert,
)


def _conn_with_cursor(cur):
    conn = MagicMock()
    cm = MagicMock()
    cm.__enter__.return_value = cur
    cm.__exit__.return_value = False
    conn.cursor.return_value = cm
    return conn


@pytest.mark.tier1
def test_batch_insert_returns_rowcount(mocker):
    cur = MagicMock(rowcount=2)
    conn = _conn_with_cursor(cur)
    fake_ev = mocker.patch("processing.common.db.batch.psycopg2.extras.execute_values")
    n = batch_insert(
        conn,
        table="schema.tbl",
        columns=("a", "b"),
        rows=[(1, "x"), (2, "y")],
    )
    assert n == 2
    assert fake_ev.call_count == 1
    rendered_sql = fake_ev.call_args.args[1]
    assert 'INSERT INTO "schema"."tbl"' in rendered_sql
    assert '("a", "b") VALUES %s' in rendered_sql


@pytest.mark.tier1
def test_batch_insert_with_on_conflict(mocker):
    cur = MagicMock(rowcount=1)
    conn = _conn_with_cursor(cur)
    fake_ev = mocker.patch("processing.common.db.batch.psycopg2.extras.execute_values")
    batch_insert(
        conn,
        table="schema.tbl",
        columns=("id", "v"),
        rows=[(1, "a")],
        on_conflict="(id) DO NOTHING",
    )
    rendered = fake_ev.call_args.args[1]
    assert "ON CONFLICT (id) DO NOTHING" in rendered


@pytest.mark.tier1
def test_empty_columns_raises():
    conn = MagicMock()
    with pytest.raises(ValueError, match="columns must be non-empty"):
        batch_insert(conn, table="t", columns=(), rows=[])


@pytest.mark.tier1
def test_integrity_error_translated(mocker):
    cur = MagicMock()
    conn = _conn_with_cursor(cur)
    mocker.patch(
        "processing.common.db.batch.psycopg2.extras.execute_values",
        side_effect=psycopg2.errors.UniqueViolation("dup"),
    )
    with pytest.raises(IntegrityError, match="dup"):
        batch_insert(conn, table="t", columns=("a",), rows=[(1,)])


@pytest.mark.tier1
def test_serialization_failure_translated_to_transient(mocker):
    cur = MagicMock()
    conn = _conn_with_cursor(cur)
    mocker.patch(
        "processing.common.db.batch.psycopg2.extras.execute_values",
        side_effect=psycopg2.errors.SerializationFailure("serial"),
    )
    with pytest.raises(TransientError):
        batch_insert(conn, table="t", columns=("a",), rows=[(1,)])


@pytest.mark.tier1
def test_other_psycopg2_error_becomes_query_error(mocker):
    cur = MagicMock()
    conn = _conn_with_cursor(cur)
    mocker.patch(
        "processing.common.db.batch.psycopg2.extras.execute_values",
        side_effect=psycopg2.Error("boom"),
    )
    with pytest.raises(QueryError, match="boom"):
        batch_insert(conn, table="t", columns=("a",), rows=[(1,)])
