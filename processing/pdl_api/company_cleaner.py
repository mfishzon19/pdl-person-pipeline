"""PDL company cleaner — `/v5/company/clean`.

Normalizes a company search payload (name / website / etc.) into a
`pdl_company_id`. Single-record pass: `CompanyCleanerCaller` subclasses the
generic `PDLCaller` and supplies only the response mapping; all the plumbing
(SKIP LOCKED claim, audit, record-then-finalize, rate-limit, stale reclaim,
retry) is inherited.

The module-level `process_cleaner_batch` wrapper is a function-style
convenience API over `CompanyCleanerCaller.process_batch`.
"""

from __future__ import annotations

import socket
import sys
import time

from processing.common.db import connect
from processing.pdl_api.base import PDLCaller, parse_drain_rpm

# Default rate limit. Caller overrides with the value PDL grants for the plan.
DEFAULT_CLEANER_RPM = 60


class CompanyCleanerCaller(PDLCaller):
    """`/v5/company/clean`. Writes the resolved `pdl_company_id` back onto the
    queue row (the enrichment view keys off it), so `map_status` returns it in
    the extras dict for the framework's finalize to persist."""

    def __init__(self, *, rate_limit_rpm=DEFAULT_CLEANER_RPM, credit_cap_per_day=None):
        super().__init__(
            endpoint_url="/v5/company/clean",
            driver_view="pdl_api.v_company_input_for_cleaner",
            queue_table="pdl_api.company_input_list",
            queue_status_column="cleaner_status",
            audit_table="pdl_api.company_cleaner_call",
            rate_limit_rpm=rate_limit_rpm,
            credit_cap_per_day=credit_cap_per_day,
        )

    # build_payload inherits the base default (returns row["request_payload"],
    # which the cleaner view exposes as pdl_search_params).

    def map_status(self, response):
        status = response["http_status"]
        body = response["body"]
        pdl_id = body.get("id") if (status == 200 and isinstance(body, dict)) else None
        if pdl_id:
            new_status = "resolved"
        elif status in (200, 404):
            # 200 with no id is a no-match, same as an explicit 404.
            new_status = "not_found"
        else:
            new_status = "error"
        # Persist pdl_company_id onto the queue row (NULL unless resolved).
        return new_status, {"pdl_company_id": pdl_id}


def process_cleaner_batch(conn, worker_id, limit=100, *,
                          requests_per_minute=DEFAULT_CLEANER_RPM,
                          sleep_fn=time.sleep):
    """Function-style wrapper over `CompanyCleanerCaller`. Claims up to
    `limit` rows from v_company_input_for_cleaner, cleans each, records audit,
    updates the queue. `requests_per_minute` paces successive calls; 0 disables.
    Returns the number of rows processed."""
    caller = CompanyCleanerCaller(rate_limit_rpm=requests_per_minute)
    return caller.process_batch(conn, worker_id, limit=limit, sleep_fn=sleep_fn)


# Runtime entrypoint (`python -m processing.pdl_api.company_cleaner drain`;
# doc 18 §Concurrency). drain() reclaims stale in_progress rows before its
# batch loop.
if __name__ == "__main__":
    rpm = parse_drain_rpm("python -m processing.pdl_api.company_cleaner",
                          sys.argv[1:], DEFAULT_CLEANER_RPM)
    conn = connect()
    try:
        n = CompanyCleanerCaller(rate_limit_rpm=rpm).drain(
            conn, f"company_cleaner@{socket.gethostname()}")
        print(f"drained {n} company rows")
    finally:
        conn.close()
