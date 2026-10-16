"""Shared test fixtures for the s3_ingester suite.

Unit tests don't talk to a real database. They use the `mock_conn` and
`mock_cursor` fixtures here to fake psycopg2.

Integration tests run against a real Postgres (S3 is faked in the test
module). They're marked `@pytest.mark.integration` and skip
on their own when DATABASE_URL isn't set.

YAML fixtures live in `fixtures/`. The `configs_dir` fixture points
`delivery_loader._CONFIGS_DIR` at that folder so `_load_source_config()`
reads our test YAMLs instead of the real configs/ folder.
"""

from __future__ import annotations

import os
from pathlib import Path
from unittest.mock import MagicMock

import pytest

FIXTURES_DIR = Path(__file__).parent / "fixtures"


def pytest_collection_modifyitems(config, items):
    """Skip integration tests when DATABASE_URL isn't set.

    The Tier 1 plan says integration tests must be opt-in. Set
    DATABASE_URL to run them, leave it unset to skip.
    """
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
    """A fake psycopg2 cursor that works inside `with cur:` blocks."""
    cur = MagicMock(name="cursor")
    cur.__enter__ = MagicMock(return_value=cur)
    cur.__exit__ = MagicMock(return_value=None)
    return cur


@pytest.fixture
def mock_conn(mock_cursor):
    """A fake psycopg2 connection.

    Works for both `with conn:` (transaction) and `with conn.cursor()`.
    Every call to `conn.cursor()` returns the same `mock_cursor`, so the
    test can read every `execute()` call across all transactions in one
    place.
    """
    conn = MagicMock(name="connection")
    conn.__enter__ = MagicMock(return_value=conn)
    conn.__exit__ = MagicMock(return_value=None)
    conn.cursor.return_value = mock_cursor
    return conn


@pytest.fixture
def configs_dir(monkeypatch):
    """Make `_load_source_config()` read from our fixtures folder."""
    from processing.s3_ingester import delivery_loader

    monkeypatch.setattr(delivery_loader, "_CONFIGS_DIR", FIXTURES_DIR)
    return FIXTURES_DIR


@pytest.fixture
def sample_partitioned_config():
    """A source config dict with partitioned-mode keys filled in."""
    return {
        "column_list": "payload",
        "copy_options": "FORMAT csv, DELIMITER E'\\x01', QUOTE E'\\x02'",
        "bucket": "test-bucket",
        "region": "us-east-1",
        "partition_column": "partition_id",
        "partition_value_type": "smallint",
    }


@pytest.fixture
def sample_flat_config():
    """A source config dict for a flat (non-partitioned) table."""
    return {
        "column_list": "payload",
        "copy_options": "FORMAT csv",
        "bucket": "test-bucket",
        "region": "us-east-1",
    }
