"""Postgres connection management and SQL execution helpers.

Public API (import from this module):

    Connection:
        connect(dsn=None)                  -> psycopg2 connection

    Execution (runs inside caller's transaction):
        execute(conn, sql, params)         -> int rowcount
        fetch_one(conn, sql, params)       -> tuple | None
        fetch_all(conn, sql, params)       -> list[tuple]
        fetch_dict_all(conn, sql, params)  -> list[dict]

    Transactions:
        transaction(conn)                  -> contextmanager

    Bulk insert:
        batch_insert(conn, *, table, columns, rows, page_size, on_conflict)

    Exceptions (catch these, not psycopg2.*):
        DBOpsError              base
        ConnectionFailed
        QueryError
        IntegrityError          (subclass of QueryError)
        TransientError          (retry-worthy)

Prefer these helpers and error types over raw psycopg2. The exceptions are
modules that need driver-specific features: `pdl_api` uses
`psycopg2.extras` (RealDictCursor, execute_values) and `s3_ingester` uses
`psycopg2.sql` for identifier quoting.
"""

from processing.common.db.batch import batch_insert
from processing.common.db.connect import connect
from processing.common.db.errors import (
    ConnectionFailed,
    DBOpsError,
    IntegrityError,
    QueryError,
    TransientError,
)
from processing.common.db.execute import (
    execute,
    fetch_all,
    fetch_dict_all,
    fetch_one,
)
from processing.common.db.transaction import transaction

__all__ = [
    "connect",
    "execute",
    "fetch_one",
    "fetch_all",
    "fetch_dict_all",
    "transaction",
    "batch_insert",
    "DBOpsError",
    "ConnectionFailed",
    "QueryError",
    "IntegrityError",
    "TransientError",
]
