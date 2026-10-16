"""Query execution helpers.

Wraps `cursor.execute(...)` + `fetchone()` / `fetchall()` with consistent
error translation so callers never touch raw psycopg2 cursors.

Functions:
    execute(conn, sql, params)         -> int (rowcount)
    fetch_one(conn, sql, params)       -> tuple | None
    fetch_all(conn, sql, params)       -> list[tuple]
    fetch_dict_all(conn, sql, params)  -> list[dict]

All four are read-only of the connection's autocommit state — they
execute against whatever transaction the caller has set up (via
`transaction()` or manual `conn.commit()`). They do NOT commit on
their own.

Parameter binding always uses psycopg2's `%s` placeholders. Never
build SQL strings via `+` / f-strings with user input. For dynamic
identifiers (table / column names) use psycopg2.sql.SQL + Identifier
at the call site; this module doesn't try to abstract that.
"""

from __future__ import annotations

from typing import Any

import psycopg2
import psycopg2.extras

from processing.common.db.errors import (
    IntegrityError,
    QueryError,
    TransientError,
)


def execute(conn, sql, params: tuple | dict | None = None) -> int:
    """Run a statement, return affected row count.

    For INSERT / UPDATE / DELETE / DDL. Use fetch_* helpers for SELECT.

    Raises:
        IntegrityError  on constraint violations.
        TransientError  on serialization / deadlock / lock timeout.
        QueryError      on any other SQL execution error.
    """
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.rowcount
    except psycopg2.errors.IntegrityError as exc:
        raise IntegrityError(str(exc)) from exc
    except (
        psycopg2.errors.SerializationFailure,
        psycopg2.errors.DeadlockDetected,
        psycopg2.errors.LockNotAvailable,
    ) as exc:
        raise TransientError(str(exc)) from exc
    except psycopg2.Error as exc:
        raise QueryError(str(exc)) from exc


def fetch_one(conn, sql, params: tuple | dict | None = None) -> tuple | None:
    """Run a SELECT and return the first row (or None if no rows)."""
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchone()
    except psycopg2.Error as exc:
        raise QueryError(str(exc)) from exc


def fetch_all(conn, sql, params: tuple | dict | None = None) -> list[tuple]:
    """Run a SELECT and return every row as a list of tuples."""
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall()
    except psycopg2.Error as exc:
        raise QueryError(str(exc)) from exc


def fetch_dict_all(
    conn, sql, params: tuple | dict | None = None,
) -> list[dict[str, Any]]:
    """Run a SELECT and return every row as a dict keyed by column name."""
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, params)
            return [dict(row) for row in cur.fetchall()]
    except psycopg2.Error as exc:
        raise QueryError(str(exc)) from exc
