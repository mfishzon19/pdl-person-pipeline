"""Unit tests for processing.common.db.execute.

psycopg2 is mocked at the cursor boundary; no live DB.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import psycopg2
import pytest

from processing.common.db import (
    IntegrityError,
    QueryError,
    TransientError,
    execute,
    fetch_all,
    fetch_dict_all,
    fetch_one,
)


def _conn_with_cursor(cur):
    """Build a conn whose `with conn.cursor() as cur:` yields `cur`."""
    conn = MagicMock()
    cm = MagicMock()
    cm.__enter__.return_value = cur
    cm.__exit__.return_value = False
    conn.cursor.return_value = cm
    return conn


@pytest.mark.tier1
def test_execute_returns_rowcount():
    cur = MagicMock(rowcount=3)
    conn = _conn_with_cursor(cur)
    assert execute(conn, "UPDATE x SET y=%s", (1,)) == 3
    cur.execute.assert_called_once_with("UPDATE x SET y=%s", (1,))


@pytest.mark.tier1
def test_fetch_one_returns_first_row_or_none():
    cur = MagicMock()
    cur.fetchone.return_value = (1, "a")
    conn = _conn_with_cursor(cur)
    assert fetch_one(conn, "SELECT a FROM b") == (1, "a")

    cur.fetchone.return_value = None
    assert fetch_one(conn, "SELECT a FROM b") is None


@pytest.mark.tier1
def test_fetch_all_returns_all_rows():
    cur = MagicMock()
    cur.fetchall.return_value = [(1,), (2,), (3,)]
    conn = _conn_with_cursor(cur)
    assert fetch_all(conn, "SELECT id FROM t") == [(1,), (2,), (3,)]


@pytest.mark.tier1
def test_fetch_dict_all_returns_dicts():
    cur = MagicMock()
    cur.fetchall.return_value = [{"id": 1, "name": "a"}, {"id": 2, "name": "b"}]
    conn = _conn_with_cursor(cur)
    assert fetch_dict_all(conn, "SELECT id, name FROM t") == [
        {"id": 1, "name": "a"},
        {"id": 2, "name": "b"},
    ]


@pytest.mark.tier1
def test_integrity_error_translated():
    cur = MagicMock()
    cur.execute.side_effect = psycopg2.errors.UniqueViolation("dup key")
    conn = _conn_with_cursor(cur)
    with pytest.raises(IntegrityError, match="dup key"):
        execute(conn, "INSERT INTO t VALUES (%s)", (1,))


@pytest.mark.tier1
def test_serialization_failure_translated_to_transient():
    cur = MagicMock()
    cur.execute.side_effect = psycopg2.errors.SerializationFailure("serial")
    conn = _conn_with_cursor(cur)
    with pytest.raises(TransientError, match="serial"):
        execute(conn, "UPDATE t SET x=1")


@pytest.mark.tier1
def test_other_psycopg2_error_becomes_query_error():
    cur = MagicMock()
    cur.execute.side_effect = psycopg2.Error("boom")
    conn = _conn_with_cursor(cur)
    with pytest.raises(QueryError, match="boom"):
        execute(conn, "SELECT 1")
