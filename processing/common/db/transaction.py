"""Transaction context manager.

Wrap a block of work in BEGIN / COMMIT, with automatic ROLLBACK on
any exception. Matches the natural psycopg2 connection.__exit__
behavior (which already commits on success / rolls back on exception)
but exposed as an explicit named context so call sites read clearly.

Usage:

    from processing.common.db import connect, transaction, execute

    with connect() as conn, transaction(conn):
        execute(conn, "INSERT INTO foo (a) VALUES (%s)", (1,))
        execute(conn, "INSERT INTO bar (b) VALUES (%s)", (2,))
        # Both commit at block exit.
        # If either raises, both roll back.

Nesting:
    psycopg2 doesn't support nested transactions on the same
    connection. Calling transaction(conn) inside an outer
    transaction(conn) re-uses the outer block — no SAVEPOINT.
    If you need SAVEPOINT semantics, use psycopg2.extensions
    directly at the call site.
"""

from __future__ import annotations

from contextlib import contextmanager

import psycopg2

from processing.common.db.errors import (
    IntegrityError,
    QueryError,
    TransientError,
)


@contextmanager
def transaction(conn):
    """Run a block of work in one transaction. Commit on success, roll back on failure.

    Raises:
        IntegrityError on constraint violations during commit.
        TransientError on serialization / deadlock at commit time.
        QueryError     on any other DB error.

    The original psycopg2 exception is chained via __cause__ so callers
    that need driver details can still get them.
    """
    try:
        yield conn
        conn.commit()
    except psycopg2.errors.IntegrityError as exc:
        conn.rollback()
        raise IntegrityError(str(exc)) from exc
    except (
        psycopg2.errors.SerializationFailure,
        psycopg2.errors.DeadlockDetected,
        psycopg2.errors.LockNotAvailable,
    ) as exc:
        conn.rollback()
        raise TransientError(str(exc)) from exc
    except psycopg2.Error as exc:
        conn.rollback()
        raise QueryError(str(exc)) from exc
    except Exception:
        conn.rollback()
        raise
