"""Shared pytest fixtures for the pdl_api test suite.

Same shape as `processing/s3_ingester/tests/conftest.py`:

  - Unit tests use `mock_conn` / `mock_cursor` to fake psycopg2.
  - Integration tests mark themselves `@pytest.mark.integration` and
    skip on their own when `DATABASE_URL` isn't set.

Per CLAUDE.md, every PDL call in tests is mocked. Tests patch
`processing.common.pdl.client.pdl_api_call` directly.
"""

from __future__ import annotations

import os
from unittest.mock import MagicMock

import pytest


def pytest_collection_modifyitems(config, items):
    """Skip integration tests when DATABASE_URL isn't set."""
    if os.environ.get("DATABASE_URL"):
        return
    skip_integration = pytest.mark.skip(
        reason="integration test, set DATABASE_URL to enable",
    )
    for item in items:
        if "integration" in item.keywords:
            item.add_marker(skip_integration)


@pytest.fixture
def mock_cursor():
    """MagicMock that behaves like a psycopg2 cursor inside `with cur:`."""
    cur = MagicMock(name="cursor")
    cur.__enter__ = MagicMock(return_value=cur)
    cur.__exit__ = MagicMock(return_value=None)
    return cur


@pytest.fixture
def mock_conn(mock_cursor):
    """MagicMock that behaves like a psycopg2 connection.

    `cursor()` returns the same `mock_cursor` for every call, so a test
    can inspect every `execute()` across all transactions in one place.
    `commit()` is just a no-op call recorder.
    """
    conn = MagicMock(name="connection")
    conn.__enter__ = MagicMock(return_value=conn)
    conn.__exit__ = MagicMock(return_value=None)
    conn.cursor.return_value = mock_cursor
    return conn


