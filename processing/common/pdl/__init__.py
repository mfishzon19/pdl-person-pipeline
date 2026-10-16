"""Generic PDL API client primitives.

HTTP POST with API-key auth, bounded retry, and response parsing. Consumed by
the ``processing.pdl_api`` callers (company enrichment and the cleaners).
Workflow-level orchestration (queue claiming, batching, audit, credit caps)
lives in ``pdl_api``, not here.
"""

from processing.common.pdl.client import (
    MAX_BACKOFF_SECONDS,
    PDL_BASE,
    RETRYABLE_HTTP_STATUS,
    call_pdl_with_retry,
    pdl_api_call,
)

__all__ = [
    "MAX_BACKOFF_SECONDS",
    "PDL_BASE",
    "RETRYABLE_HTTP_STATUS",
    "call_pdl_with_retry",
    "pdl_api_call",
]
