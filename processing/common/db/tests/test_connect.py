"""Unit tests for processing.common.db.connect.

psycopg2.connect is mocked; no live DB.
"""

from __future__ import annotations

import pytest

from processing.common.db import connect

_PSYCOPG2_CONNECT = "psycopg2.connect"


@pytest.mark.tier1
def test_explicit_dsn_wins(mocker):
    """An explicit dsn is passed straight to psycopg2.connect."""
    fake = mocker.patch(_PSYCOPG2_CONNECT)
    connect("postgresql://u:p@h:5432/d")
    fake.assert_called_once_with("postgresql://u:p@h:5432/d")


@pytest.mark.tier1
def test_database_url_used_when_no_dsn(mocker, monkeypatch):
    """No dsn -> DATABASE_URL env var."""
    monkeypatch.setenv("DATABASE_URL", "postgresql://env-url")
    fake = mocker.patch(_PSYCOPG2_CONNECT)
    connect()
    fake.assert_called_once_with("postgresql://env-url")


@pytest.mark.tier1
def test_libpq_fallthrough(mocker, monkeypatch):
    """No dsn, no DATABASE_URL -> psycopg2.connect('') so libpq reads PG*."""
    monkeypatch.delenv("DATABASE_URL", raising=False)
    fake = mocker.patch(_PSYCOPG2_CONNECT)
    connect()
    fake.assert_called_once_with("")
