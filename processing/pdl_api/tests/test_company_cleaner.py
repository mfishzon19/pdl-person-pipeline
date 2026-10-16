"""Unit tests for the company cleaner. Mocked; no live PDL."""

from __future__ import annotations

import pytest

from processing.pdl_api import company_cleaner as mod

_PDL_API_CALL_PATCH = "processing.common.pdl.client.pdl_api_call"


def _pdl_result(http_status, body=None, latency_ms=5, error_message=None):
    return {"http_status": http_status, "body": body,
            "latency_ms": latency_ms, "error_message": error_message}


@pytest.mark.tier1
def test_map_status_resolves_pdl_id():
    """200 with id -> ('resolved', {pdl_company_id})."""
    caller = mod.CompanyCleanerCaller()
    assert caller.map_status(_pdl_result(200, body={"id": "co-1"})) == (
        "resolved", {"pdl_company_id": "co-1"})


@pytest.mark.tier1
def test_map_status_no_id_is_not_found():
    """200 with no id, and 404, both -> ('not_found', {pdl_company_id: None})."""
    caller = mod.CompanyCleanerCaller()
    assert caller.map_status(_pdl_result(200, body={})) == ("not_found", {"pdl_company_id": None})
    assert caller.map_status(_pdl_result(404, body=None)) == ("not_found", {"pdl_company_id": None})


@pytest.mark.tier1
def test_map_status_error():
    caller = mod.CompanyCleanerCaller()
    assert caller.map_status(_pdl_result(500, body=None)) == ("error", {"pdl_company_id": None})


@pytest.mark.tier1
def test_finalize_writes_status_and_pdl_id(mock_conn):
    """The atomic record+finalize sets cleaner_status + pdl_company_id on the
    queue, clearing worker/claim (no duplicate columns)."""
    mock_conn.cursor.return_value.rowcount = 1
    caller = mod.CompanyCleanerCaller()
    status, extras = caller.map_status(_pdl_result(200, body={"id": "co-1"}))
    caller._record_and_finalize(
        mock_conn, "w", 42, {"name": "x"}, _pdl_result(200, body={"id": "co-1"}),
        status, extras)
    updates = [c.args for c in mock_conn.cursor.return_value.execute.call_args_list
               if "UPDATE pdl_api.company_input_list" in c.args[0]]
    assert updates, "expected a queue UPDATE"
    sql, params = updates[-1]
    assert "cleaner_status = %s" in sql and "pdl_company_id = %s" in sql
    # guarded finalize
    assert "WHERE id = %s AND worker_id = %s" in sql
    assert "cleaner_status = 'in_progress'" in sql
    # exact params + order: SET pdl_company_id, cleaner_status, worker_id=NULL,
    # claimed_at=NULL ; WHERE id=42, worker_id='w' (catches a column-swap)
    assert params == ["co-1", "resolved", None, None, 42, "w"]


@pytest.mark.tier1
def test_process_cleaner_batch_throttles_between_calls(mocker, mock_conn):
    """rpm=120 -> a pause between successive calls (3 rows -> 2 sleeps)."""
    mocker.patch("processing.pdl_api.base.cap_reached", return_value=False)
    mocker.patch("processing.pdl_api.base.PDLCaller._claim", return_value=[
        {"input_list_id": 1, "request_payload": {"name": "A"}},
        {"input_list_id": 2, "request_payload": {"name": "B"}},
        {"input_list_id": 3, "request_payload": {"name": "C"}},
    ])
    mocker.patch(_PDL_API_CALL_PATCH, return_value=_pdl_result(200, body={"id": "x"}))
    mocker.patch("processing.pdl_api.base.PDLCaller._record_and_finalize")

    sleeps = []
    n = mod.process_cleaner_batch(
        mock_conn, "w", requests_per_minute=120,
        sleep_fn=lambda s: sleeps.append(s),
    )
    assert n == 3
    assert len(sleeps) == 2          # paced between the 3 calls
    # 120 rpm => 0.5s min interval; mocked call body is instant, so each pause is
    # essentially the full interval. Tight window catches a pacing regression
    # (e.g. 0.008s intervals) that a broad 0 < s <= 0.5 would let pass.
    assert all(0.49 < s <= 0.5 for s in sleeps)
