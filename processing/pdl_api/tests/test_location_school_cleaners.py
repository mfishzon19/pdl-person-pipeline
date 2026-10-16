"""Tiny mocked tests for the two cleaner subclasses. They inherit the
base wholesale, so only map_status needs checking."""

from __future__ import annotations

import pytest

from processing.pdl_api.location_cleaner import LocationCleanerCaller
from processing.pdl_api.school_cleaner import SchoolCleanerCaller


def _r(http_status, body=None):
    return {"http_status": http_status, "body": body, "latency_ms": 1, "error_message": None}


@pytest.mark.tier1
def test_location_map_status_resolves_on_name_not_id():
    """/v5/location/clean returns NO top-level id — a resolved location is a 200
    carrying a composite `name`. Fixture mirrors the PDL response shape."""
    c = LocationCleanerCaller()
    real_200 = {"name": "austin, texas, united states", "locality": "austin",
                "region": "texas", "country": "united states", "type": "locality"}
    assert c.map_status(_r(200, real_200)) == ("resolved", {})
    assert c.map_status(_r(200, {})) == ("not_found", {})     # 200, no name -> no match
    assert c.map_status(_r(404, None)) == ("not_found", {})
    assert c.map_status(_r(500, None)) == ("error", {})


@pytest.mark.tier1
def test_school_map_status_resolves_on_id():
    """/v5/school/clean DOES return a top-level id (unlike location)."""
    c = SchoolCleanerCaller()
    assert c.map_status(_r(200, {"id": "example-school-id", "name": "example university"})) == (
        "resolved", {})
    assert c.map_status(_r(200, {})) == ("not_found", {})
    assert c.map_status(_r(404, None)) == ("not_found", {})
    assert c.map_status(_r(500, None)) == ("error", {})


@pytest.mark.tier1
def test_endpoints_wired():
    assert LocationCleanerCaller().endpoint_url == "/v5/location/clean"
    assert LocationCleanerCaller().queue_table == "pdl_api.location_input_list"
    assert SchoolCleanerCaller().endpoint_url == "/v5/school/clean"
    assert SchoolCleanerCaller().audit_table == "pdl_api.school_cleaner_call"
