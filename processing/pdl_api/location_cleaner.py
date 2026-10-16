"""PDL location cleaner — `/v5/location/clean`.

Normalizes a raw address string into a canonical PDL location. Single-record
pass; a small subclass of the generic `PDLCaller` — all plumbing is
inherited. The request body is shaped by `pdl_api.v_location_input`
(`{"location": raw_input}`). Unlike company/school clean, /v5/location/clean
returns NO entity id — the canonical value is the composite `name`, captured by
the audit table's generated `cleaned_location` column; nothing is written back
onto the queue.

Runtime contract: `python -m processing.pdl_api.location_cleaner drain`.
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
DEFAULT_LOCATION_CLEANER_RPM = 60


class LocationCleanerCaller(PDLCaller):
    """`/v5/location/clean`. Inherits the default build_payload (uses the
    view's request_payload). No queue-side id write-back (unlike company)."""

    def __init__(self, *, rate_limit_rpm=DEFAULT_LOCATION_CLEANER_RPM,
                 credit_cap_per_day=None):
        super().__init__(
            endpoint_url="/v5/location/clean",
            driver_view="pdl_api.v_location_input",
            queue_table="pdl_api.location_input_list",
            queue_status_column="cleaner_status",
            audit_table="pdl_api.location_cleaner_call",
            rate_limit_rpm=rate_limit_rpm,
            credit_cap_per_day=credit_cap_per_day,
        )

    def map_status(self, response):
        # /v5/location/clean returns NO top-level id — a resolved location is a
        # 200 carrying a canonical composite `name` ("austin, texas, united
        # states"). Gate on `name`, not `id` (gating on `id` would route every
        # 200 to not_found). The canonical
        # value is persisted by the audit's generated `cleaned_location` column;
        # nothing is written back onto the queue, so extras stays empty.
        status = response["http_status"]
        body = response["body"]
        if status == 200 and isinstance(body, dict) and body.get("name"):
            return "resolved", {}
        if status in (200, 404):
            return "not_found", {}
        return "error", {}


# Runtime entrypoint (`python -m ... drain`), run locally by hand or from a
# scheduler (cron, make target) — not a demo. No interactive confirm guard (an
# unattended invocation must not block on a prompt). drain() reclaims stale
# in_progress rows before its batch loop, so a crashed run self-recovers.
if __name__ == "__main__":
    rpm = parse_drain_rpm("python -m processing.pdl_api.location_cleaner",
                          sys.argv[1:], DEFAULT_LOCATION_CLEANER_RPM)
    conn = connect()
    try:
        n = LocationCleanerCaller(rate_limit_rpm=rpm).drain(
            conn, f"location@{socket.gethostname()}")
        print(f"drained {n} location rows")
    finally:
        conn.close()
