"""Exception hierarchy for processing.common.aws helpers.

Wraps botocore exceptions in stable types so callers can catch on
intent without importing botocore directly.

Hierarchy:

    AWSOpsError
      ├── NotFound          # ResourceNotFoundException / NoSuchKey
      ├── AccessDenied      # AccessDenied / 403
      └── TransientError    # throttling / 5xx — safe to retry
"""

from __future__ import annotations


class AWSOpsError(Exception):
    """Base class for all aws helper errors. Catch this to be defensive."""


class NotFound(AWSOpsError):
    """The requested resource (secret / object / role) does not exist."""


class AccessDenied(AWSOpsError):
    """The current credentials are not authorized for this call."""


class TransientError(AWSOpsError):
    """Throttling / 5xx / network failure — caller can retry with backoff."""
