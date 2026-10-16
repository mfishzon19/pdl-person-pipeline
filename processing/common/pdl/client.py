"""Generic PDL API HTTP client.

Endpoint-agnostic POST + bounded retry. The caller passes the
endpoint path and payload. Reads the PDL API key from PDL_API_KEY.
"""

from __future__ import annotations

import os
import random
import time

import requests

PDL_BASE = "https://api.peopledatalabs.com"

# Retried on 429, 5xx, and network errors (http_status=None).
RETRYABLE_HTTP_STATUS = frozenset({429, 502, 503, 504})
MAX_BACKOFF_SECONDS = 60.0
DEFAULT_MAX_RETRIES = 5


def pdl_api_call(endpoint, payload):
    """POST a payload to a PDL endpoint and return the result.

    Args:
      endpoint: PDL endpoint path, e.g. "/v5/company/clean",
                "/v5/company/enrich/bulk", "/v5/location/clean".
      payload:  request body as a dict.

    Returns:
      {
        "http_status":   int | None,    # None on transport failure
        "body":          Any | None,    # parsed JSON or None
        "latency_ms":    int,
        "error_message": str | None,
        "retry_after":   float | None,  # seconds parsed from Retry-After
                                        # header when present, else None
      }
    """
    started = time.monotonic()
    try:
        resp = requests.post(
            PDL_BASE + endpoint,
            headers={
                "X-Api-Key": os.environ["PDL_API_KEY"],
                "Accept": "application/json",
            },
            json=payload,
            timeout=30,
        )
        latency_ms = int((time.monotonic() - started) * 1000)
        try:
            body = resp.json()
        except ValueError:
            body = None
        return {
            "http_status":   resp.status_code,
            "body":          body,
            "latency_ms":    latency_ms,
            "error_message": None,
            "retry_after":   _parse_retry_after(resp.headers.get("Retry-After")),
        }
    except requests.RequestException as e:
        return {
            "http_status":   None,
            "body":          None,
            "latency_ms":    int((time.monotonic() - started) * 1000),
            "error_message": str(e),
            "retry_after":   None,
        }


def _parse_retry_after(header_value):
    """Parse a `Retry-After` header. Returns seconds as float or None.

    The header may be an int/float seconds value, or an HTTP-date. We
    only handle the seconds form because that's what PDL actually sends
    on 429. Anything else returns None and the caller falls back to
    exponential backoff.
    """
    if not header_value:
        return None
    try:
        return float(header_value)
    except (TypeError, ValueError):
        return None


def call_pdl_with_retry(endpoint, payload, *,
                        max_retries=DEFAULT_MAX_RETRIES,
                        sleep_fn=time.sleep):
    """Call PDL with bounded retries on 429 / 5xx / transport errors.

    Wraps `pdl_api_call` with exponential backoff + jitter so a transient
    rate-limit hit doesn't poison the caller's record. Non-retryable
    responses (2xx, 4xx other than 429) return on the first attempt.
    After `max_retries`, returns the last result so the caller can still
    audit the failure cleanly.

    Args:
      endpoint, payload: forwarded to pdl_api_call.
      max_retries:       max retries after the first attempt (default 5).
      sleep_fn:          time.sleep by default; tests inject a stub.

    Returns the same dict shape as pdl_api_call.
    """
    attempt = 0
    while True:
        result = pdl_api_call(endpoint, payload)
        status = result["http_status"]
        # None == transport failure (connection / timeout). Treat as
        # retryable; the next attempt may succeed.
        retryable = status is None or status in RETRYABLE_HTTP_STATUS
        if not retryable or attempt >= max_retries:
            return result
        attempt += 1
        # Honour PDL's Retry-After header when present (precise, capped
        # at the global ceiling); otherwise jittered exponential backoff.
        hint = result.get("retry_after")
        delay = min(hint, MAX_BACKOFF_SECONDS) if hint else _backoff_seconds(attempt)
        sleep_fn(delay)


def _backoff_seconds(attempt):
    """Exponential backoff with jitter. `attempt` starts at 1.

    Returns a value in [base, 1.5 * base], clamped overall to
    `MAX_BACKOFF_SECONDS` so a tall retry budget can't sleep us past
    the documented ceiling.
    """
    base = min(MAX_BACKOFF_SECONDS, 2 ** (attempt - 1))
    return min(MAX_BACKOFF_SECONDS, base + random.uniform(0, 0.5 * base))  # noqa: S311 (backoff jitter, not crypto)
