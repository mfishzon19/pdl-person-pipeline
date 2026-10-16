"""Unit tests for company_enrichment.

Mocked cases that pin logic the live PDL smoke + integration suites
can't easily exercise: retry handling, the bulk cap, run_enrichment's
safeguards, and the record-before-finalize ordering.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from processing.common.pdl import call_pdl_with_retry
from processing.pdl_api import company_enrichment as mod

# Patch target for the wrapped HTTP call. call_pdl_with_retry lives in
# processing.common.pdl.client and calls pdl_api_call from its own module
# scope, so the patch has to target the source module not the company_
# enrichment alias.
_PDL_API_CALL_PATCH = "processing.common.pdl.client.pdl_api_call"


def _pdl_result(http_status, body=None, latency_ms=5,
                error_message=None, retry_after=None):
    return {
        "http_status":   http_status,
        "body":          body,
        "latency_ms":    latency_ms,
        "error_message": error_message,
        "retry_after":   retry_after,
    }


@pytest.fixture
def mock_conn():
    cur = MagicMock()
    cur.__enter__ = MagicMock(return_value=cur)
    cur.__exit__ = MagicMock(return_value=None)
    conn = MagicMock()
    conn.cursor.return_value = cur
    conn._cursor = cur
    return conn


@pytest.mark.tier1
def test_retry_recovers_from_429_using_retry_after(mocker):
    """One 429 with Retry-After then a 200. Sleep exactly the header
    value and end on the success."""
    responses = iter([
        _pdl_result(429, body={}, retry_after=7.5),
        _pdl_result(200, body={"id": "co-1"}),
    ])
    mocker.patch(_PDL_API_CALL_PATCH, side_effect=lambda *a, **kw: next(responses))

    sleeps = []
    r = call_pdl_with_retry(
        "/v5/company/clean", {"name": "x"},
        sleep_fn=lambda s: sleeps.append(s),
    )
    assert r["http_status"] == 200
    assert sleeps == [7.5]


@pytest.mark.tier1
def test_retry_does_not_retry_4xx(mocker):
    """400 is a real answer, not transient. Return on first call."""
    mocker.patch(_PDL_API_CALL_PATCH,
                 return_value=_pdl_result(400, body={"error": "bad request"}))
    sleeps = []
    r = call_pdl_with_retry(
        "/v5/company/clean", {"name": "x"},
        sleep_fn=lambda s: sleeps.append(s),
    )
    assert r["http_status"] == 400
    assert sleeps == []


@pytest.mark.tier1
def test_process_enrichment_batch_rejects_over_bulk_cap(mock_conn):
    """limit>100 fails before any DB write (PDL's bulk cap is 100)."""
    with pytest.raises(ValueError, match="exceeds PDL bulk cap"):
        mod.process_enrichment_batch(mock_conn, "w", limit=101)


# -----------------------------------------------------------------------------
# Safeguards: RateLimiter + run_enrichment
# -----------------------------------------------------------------------------

@pytest.mark.tier1
def test_rate_limiter_paces_to_min_interval():
    """120 rpm -> 0.5s min gap. First call free; a call 0.1s later sleeps 0.4s."""
    ticks = [0.0]
    slept = []
    rl = mod.RateLimiter(120, sleep_fn=lambda s: slept.append(round(s, 3)),
                         time_fn=lambda: ticks[0])
    rl.wait()
    assert slept == []          # first call never blocks
    ticks[0] = 0.1
    rl.wait()
    assert slept == [0.4]       # 0.5 interval - 0.1 already elapsed


@pytest.mark.tier1
def test_run_enrichment_stops_at_credit_cap_and_clamps_batch(mock_conn, mocker):
    """Credit cap is a hard ceiling; the final batch is clamped so the run
    can't overshoot. cap=250, batch=100 -> 100 + 100 + 50."""
    state = {"spent": 0}
    sizes = []

    def fake_batch(conn, worker_id, limit, source_list=None):
        sizes.append(limit)
        state["spent"] += limit          # pretend every company enriches
        return limit

    mocker.patch.object(mod, "reclaim_stale_enrichment", return_value=(0, 0))
    mocker.patch.object(mod, "requeue_retryable_errors", return_value=0)
    mocker.patch.object(mod, "process_enrichment_batch", side_effect=fake_batch)
    mocker.patch.object(mod, "_credits_spent",
                        side_effect=lambda conn, sl=None: state["spent"])

    total = mod.run_enrichment(mock_conn, "w", "L", max_credits=250,
                               batch_size=100, requests_per_minute=0)
    assert sizes == [100, 100, 50]
    assert total == 250
    assert state["spent"] == 250


@pytest.mark.tier1
def test_run_enrichment_requeues_errors_then_stops_when_dry(mock_conn, mocker):
    """When the pending queue drains (batch returns 0), retry errored rows;
    stop only once a requeue pass turns up nothing."""
    mocker.patch.object(mod, "reclaim_stale_enrichment", return_value=(0, 0))
    mocker.patch.object(mod, "process_enrichment_batch", return_value=0)
    mocker.patch.object(mod, "_credits_spent", return_value=0)
    requeue = mocker.patch.object(mod, "requeue_retryable_errors",
                                  side_effect=[3, 0])

    total = mod.run_enrichment(mock_conn, "w", "L", max_credits=100,
                               requests_per_minute=0)
    assert requeue.call_count == 2     # first requeues 3, second finds none
    assert total == 0


@pytest.mark.tier1
def test_run_enrichment_rejects_batch_over_cap(mock_conn):
    """batch_size>100 fails before any work."""
    with pytest.raises(ValueError, match="exceeds PDL bulk cap"):
        mod.run_enrichment(mock_conn, "w", "L", max_credits=10, batch_size=101)


@pytest.mark.tier1
def test_resolve_item_missing_records_null_body():
    """A missing response slot (truncation / dropped) maps to NULL status +
    NULL body so it reads as 'no data' (retryable), never a false success."""
    br = {"http_status": 200, "error_message": None, "latency_ms": 5}
    status, body, err = mod._resolve_item({"status": 200, "id": "c1"}, br)
    assert status == 200 and body is not None and err is None
    status, body, err = mod._resolve_item(None, br)
    assert status is None and body is None and err  # message set


@pytest.mark.tier1
def test_enrichment_batch_persists_response_before_finalize(mocker, mock_conn):
    """The anti-double-charge invariant: the full response is written
    (record) BEFORE the queue is finalized, and skips come last. The base
    orchestration drives the ordering; the record + skip steps are the class's
    company hooks, finalize is the generic base step."""
    mocker.patch("processing.pdl_api.base.cap_reached", return_value=False)
    mocker.patch.object(mod, "_claim_enrichment_rows", return_value=[
        {"id": 1, "pdl_company_id": "c1", "passthrough_params": None},
        {"id": 2, "pdl_company_id": "c2", "passthrough_params": None},
    ])
    mocker.patch.object(mod, "_next_bulk_batch_id", return_value=99)
    mocker.patch(_PDL_API_CALL_PATCH, return_value=_pdl_result(200, body=[
        {"status": 200, "metadata": {"input_list_id": 1}, "id": "c1"},
        {"status": 200, "metadata": {"input_list_id": 2}, "id": "c2"},
    ]))
    order = []
    mocker.patch.object(mod, "_record_enrichment_calls_bulk",
                        side_effect=lambda *a, **k: order.append("record"))
    mocker.patch("processing.pdl_api.base.BulkPDLCaller._finalize_batch",
                 side_effect=lambda *a, **k: order.append("finalize"))
    mocker.patch.object(mod, "_mark_sibling_skips",
                        side_effect=lambda *a, **k: order.append("skip"))

    n = mod.process_enrichment_batch(mock_conn, "w", limit=2, source_list="L")
    assert n == 2
    assert order == ["record", "finalize", "skip"]
