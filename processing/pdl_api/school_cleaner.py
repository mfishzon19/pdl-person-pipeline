"""PDL school cleaner — `/v5/school/clean`.

Normalizes a raw school string into a `pdl_school_id`. Single-record pass;
a small subclass of `PDLCaller`. The request body is shaped by
`pdl_api.v_school_input`; the resolved id is captured by the audit table's
generated `pdl_school_id` column.

Runtime contract: `python -m processing.pdl_api.school_cleaner drain`.
"""

from __future__ import annotations

import socket
import sys

from processing.common.db import connect
from processing.pdl_api.base import PDLCaller, parse_drain_rpm

# rpm is advisory (design 18 §Rate limits — the real throttle is account-wide in
# common/pdl). 60 matches the company cleaner default. No per-endpoint daily
# credit cap by default (credit_cap_per_day=None); set one only once a PDL plan
# limit calls for it.
DEFAULT_SCHOOL_CLEANER_RPM = 60


class SchoolCleanerCaller(PDLCaller):
    """`/v5/school/clean`. Same shape as the location cleaner; the request-body
    key is set by v_school_input in the migration."""

    def __init__(self, *, rate_limit_rpm=DEFAULT_SCHOOL_CLEANER_RPM,
                 credit_cap_per_day=None):
        super().__init__(
            endpoint_url="/v5/school/clean",
            driver_view="pdl_api.v_school_input",
            queue_table="pdl_api.school_input_list",
            queue_status_column="cleaner_status",
            audit_table="pdl_api.school_cleaner_call",
            rate_limit_rpm=rate_limit_rpm,
            credit_cap_per_day=credit_cap_per_day,
        )

    def map_status(self, response):
        status = response["http_status"]
        body = response["body"]
        if status == 200 and isinstance(body, dict) and body.get("id"):
            return "resolved", {}
        if status in (200, 404):
            return "not_found", {}
        return "error", {}


# Runtime entrypoint (`python -m ... drain`), run locally by hand or from a
# scheduler (cron, make target) — not a demo. No interactive confirm guard (an
# unattended invocation must not block on a prompt). drain() reclaims stale
# in_progress rows before its batch loop, so a crashed run self-recovers.
# A one-time backfill of a large queue can raise pacing with `drain --rpm N`.
if __name__ == "__main__":
    rpm = parse_drain_rpm("python -m processing.pdl_api.school_cleaner",
                          sys.argv[1:], DEFAULT_SCHOOL_CLEANER_RPM)
    conn = connect()
    try:
        n = SchoolCleanerCaller(rate_limit_rpm=rpm).drain(
            conn, f"school@{socket.gethostname()}")
        print(f"drained {n} school rows")
    finally:
        conn.close()
