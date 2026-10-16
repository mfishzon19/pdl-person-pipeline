"""Live PDL smoke tests. Skipped unless PDL_API_KEY is set.

Run with: pytest -m pdl_smoke processing/pdl_api/tests/test_pdl_smoke.py

Cleaner endpoint only. Five calls total. They validate the
wire-level path that the mocked unit suite cannot: real request
signing, response parsing, 200 / 404 status handling, and the
end-to-end retry wrapper against a live endpoint.

The lookups need a company PDL actually knows, so the inputs come from
the environment (any well-known company works); each test skips when its
variable is unset:

  PDL_SMOKE_COMPANY_NAME      e.g. "Acme Corp"
  PDL_SMOKE_COMPANY_WEBSITE   e.g. "acme.example"
  PDL_SMOKE_COMPANY_PROFILE   e.g. "linkedin.com/company/acme"

Default `pytest` deselects these (`-m "not pdl_smoke"` in pyproject
addopts), so the default run stays offline even with PDL_API_KEY exported.
"""

from __future__ import annotations

import os

import pytest

from processing.common.pdl import call_pdl_with_retry, pdl_api_call

pytestmark = [
    pytest.mark.pdl_smoke,
    pytest.mark.skipif(
        not os.environ.get("PDL_API_KEY"),
        reason="PDL_API_KEY not set; live smoke skipped",
    ),
]


def _env_input(var):
    value = os.environ.get(var)
    if not value:
        pytest.skip(f"{var} not set")
    return value


def test_smoke_cleaner_well_known_company_by_name():
    """A well-known company name resolves to a pdl_company_id, name,
    and website."""
    name = _env_input("PDL_SMOKE_COMPANY_NAME")
    r = pdl_api_call("/v5/company/clean", {"name": name})

    assert r["http_status"] == 200
    assert r["error_message"] is None
    assert r["latency_ms"] > 0

    body = r["body"]
    assert isinstance(body, dict)
    assert body.get("id"), f"expected an id in body, got {body!r}"
    assert body.get("name")
    assert body.get("website")


def test_smoke_cleaner_returns_404_for_nonsense():
    """Junk name -> PDL returns a clean 404 with status + message in
    the body, not a transport error."""
    r = pdl_api_call(
        "/v5/company/clean",
        {"name": "asdkfjhasdkjfhasdkjfh-unlikely-co"},
    )

    assert r["http_status"] == 404
    assert r["error_message"] is None
    assert isinstance(r["body"], dict)


def test_smoke_cleaner_by_website():
    """Cleaner can match by website alone — different code path on
    PDL's side, same response shape."""
    website = _env_input("PDL_SMOKE_COMPANY_WEBSITE")
    r = pdl_api_call("/v5/company/clean", {"website": website})

    assert r["http_status"] == 200
    body = r["body"]
    assert isinstance(body, dict)
    assert body.get("id"), f"expected an id in body, got {body!r}"


def test_smoke_cleaner_by_linkedin_profile():
    """Cleaner can match by LinkedIn profile URL — different code path
    on PDL's side from the name/website routes."""
    profile = _env_input("PDL_SMOKE_COMPANY_PROFILE")
    r = pdl_api_call("/v5/company/clean", {"profile": profile})

    assert r["http_status"] == 200
    body = r["body"] or {}
    assert body.get("id")
    assert body.get("name")


def test_smoke_retry_wrapper_passes_real_200_through_without_sleeping():
    """End-to-end: call_pdl_with_retry should return on the first
    call against a healthy endpoint and never sleep."""
    name = _env_input("PDL_SMOKE_COMPANY_NAME")
    sleeps = []
    r = call_pdl_with_retry(
        "/v5/company/clean", {"name": name},
        sleep_fn=lambda s: sleeps.append(s),
    )

    assert r["http_status"] == 200
    assert sleeps == []
    assert r["body"] and r["body"].get("id")
