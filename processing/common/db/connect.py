"""Postgres connection helper.

One place to open a psycopg2 connection so callers don't repeat the
DATABASE_URL / PG* env-var handling: an explicit DSN wins, then
DATABASE_URL, then libpq's standard PG* env vars.
"""

from __future__ import annotations

import os

import psycopg2


def connect(dsn=None):
    """Open a psycopg2 connection.

    Resolution order:
      1. `dsn` argument, if given (an explicit connection string).
      2. `DATABASE_URL` env var.
      3. libpq defaults: `psycopg2.connect("")` picks up `PGHOST` /
         `PGPORT` / `PGUSER` / `PGPASSWORD` / `PGDATABASE`.

    The local docker Postgres or any other Postgres works without code
    changes.
    """
    if dsn:
        return psycopg2.connect(dsn)
    url = os.environ.get("DATABASE_URL")
    if url:
        return psycopg2.connect(url)
    return psycopg2.connect("")
