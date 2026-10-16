"""Batch-insert helper.

Bulk loads many rows in one round trip using psycopg2's `execute_values`,
significantly faster than executemany() for large batches.

Usage:

    from processing.common.db import batch_insert

    rows = [(1, "a"), (2, "b"), (3, "c")]
    batch_insert(
        conn,
        table="my_schema.my_table",
        columns=("id", "name"),
        rows=rows,
    )

The caller manages the transaction (use `transaction(conn)` around
the call). batch_insert does NOT commit on its own.

Identifier quoting: `table` and `columns` are quoted with the standard
PostgreSQL `"ident"` form. These are expected to come from controlled
config (Flyway / DBML / pipeline yaml), not user input — this is not a
SQL-injection boundary.

Page size: default 1000 rows per server round trip. Override via
`page_size` for very wide or very narrow rows.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence

import psycopg2
import psycopg2.extras

from processing.common.db.errors import (
    IntegrityError,
    QueryError,
    TransientError,
)


def _quote_ident(s: str) -> str:
    """Standard PostgreSQL identifier quoting: `"ident"` with `"` doubled."""
    return '"' + s.replace('"', '""') + '"'


def batch_insert(
    conn,
    *,
    table: str,
    columns: Sequence[str],
    rows: Iterable[Sequence],
    page_size: int = 1000,
    on_conflict: str | None = None,
) -> int:
    """Insert many rows in one statement.

    Args:
        conn:        Open psycopg2 connection.
        table:       Table name. Supports `"schema.table"` or just `"table"`.
        columns:     Sequence of column names. Quoted as identifiers.
        rows:        Iterable of row tuples / sequences. Length per row
                     must match `columns` length.
        page_size:   Rows per server round trip. Default 1000.
        on_conflict: Optional ON CONFLICT clause body (without the
                     leading "ON CONFLICT"). E.g.
                     "(id) DO NOTHING" or
                     "(id) DO UPDATE SET name=EXCLUDED.name".
                     Pass None to omit the clause entirely.

    Returns:
        Number of rows the server reported written (cur.rowcount).

    Raises:
        IntegrityError  on constraint violations.
        TransientError  on serialization / deadlock / lock timeout.
        QueryError      on any other SQL execution error.
    """
    if not columns:
        raise ValueError("columns must be non-empty")

    schema, sep, name = table.partition(".")
    if sep:
        target = f"{_quote_ident(schema)}.{_quote_ident(name)}"
    else:
        target = _quote_ident(table)

    cols = ", ".join(_quote_ident(c) for c in columns)

    sql_text = f"INSERT INTO {target} ({cols}) VALUES %s"
    if on_conflict:
        sql_text = f"{sql_text} ON CONFLICT {on_conflict}"

    try:
        with conn.cursor() as cur:
            psycopg2.extras.execute_values(
                cur, sql_text, rows, page_size=page_size,
            )
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
