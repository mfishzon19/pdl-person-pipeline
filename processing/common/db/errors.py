"""Exception hierarchy for processing.common.db helpers.

Wraps psycopg2 driver exceptions in a small set of stable types so
callers can catch on intent (connection failed, integrity violation,
transient retry-worthy error) without importing psycopg2 directly.

Callers should never import psycopg2.errors. They import from here.

Hierarchy:

    DBOpsError
      ├── ConnectionFailed       # could not open / lost connection
      ├── QueryError             # SQL execution failed
      │     └── IntegrityError   # UNIQUE / FK / NOT NULL violations
      └── TransientError         # serialization / deadlock / lock timeout
                                 # — safe to retry
"""

from __future__ import annotations


class DBOpsError(Exception):
    """Base class for all db_ops errors. Catch this to be defensive."""


class ConnectionFailed(DBOpsError):
    """Failed to open the connection or it dropped mid-operation."""


class QueryError(DBOpsError):
    """SQL execution failed (syntax, type, runtime check, etc.)."""


class IntegrityError(QueryError):
    """A unique / foreign-key / not-null / check constraint tripped."""


class TransientError(DBOpsError):
    """Serialization failure, deadlock, or lock timeout — caller can retry."""
