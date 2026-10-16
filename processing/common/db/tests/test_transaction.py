"""Unit tests for processing.common.db.transaction.

psycopg2 is mocked; no live DB.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import psycopg2
import pytest

from processing.common.db import (
    IntegrityError,
    QueryError,
    TransientError,
    transaction,
)


@pytest.mark.tier1
def test_commits_on_success():
    conn = MagicMock()
    with transaction(conn):
        pass
    conn.commit.assert_called_once()
    conn.rollback.assert_not_called()


@pytest.mark.tier1
def test_rolls_back_on_plain_exception():
    conn = MagicMock()
    with pytest.raises(RuntimeError, match="boom"):
        with transaction(conn):
            raise RuntimeError("boom")
    conn.commit.assert_not_called()
    conn.rollback.assert_called_once()


@pytest.mark.tier1
def test_integrity_error_translated_and_rolled_back():
    conn = MagicMock()
    with pytest.raises(IntegrityError, match="dup"):
        with transaction(conn):
            raise psycopg2.errors.UniqueViolation("dup")
    conn.rollback.assert_called_once()


@pytest.mark.tier1
def test_deadlock_translated_to_transient():
    conn = MagicMock()
    with pytest.raises(TransientError, match="deadlock"):
        with transaction(conn):
            raise psycopg2.errors.DeadlockDetected("deadlock")
    conn.rollback.assert_called_once()


@pytest.mark.tier1
def test_other_psycopg2_error_becomes_query_error():
    conn = MagicMock()
    with pytest.raises(QueryError, match="boom"):
        with transaction(conn):
            raise psycopg2.Error("boom")
    conn.rollback.assert_called_once()
