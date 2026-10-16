"""Unit tests for the generic caller bases. Mocked; no live PDL / DB.

Covers the single-record `PDLCaller`, the shared module helpers, and the bulk
orchestration in `BulkPDLCaller`: atomic record+finalize, stale-minutes
clamp, credit cap consulted before claiming, finalize column dedup."""

from __future__ import annotations

import pytest

from processing.pdl_api import base
from processing.pdl_api.base import BulkPDLCaller, PDLCaller

_PDL_API_CALL_PATCH = "processing.common.pdl.client.pdl_api_call"


class _FakeCaller(PDLCaller):
    def __init__(self, **kw):
        super().__init__(
            endpoint_url="/v5/fake/clean",
            driver_view="pdl_api.v_fake_input",
            queue_table="pdl_api.fake_input_list",
            queue_status_column="cleaner_status",
            audit_table="pdl_api.fake_call",
            rate_limit_rpm=kw.get("rate_limit_rpm", 0),
            credit_cap_per_day=kw.get("credit_cap_per_day"),
            credit_cap_per_month=kw.get("credit_cap_per_month"),
        )

    def map_status(self, response):
        return ("resolved", {}) if response["http_status"] == 200 else ("error", {})


def _pdl_result(http_status, body=None):
    return {"http_status": http_status, "body": body, "latency_ms": 1, "error_message": None}


# --------------------------- module helpers --------------------------- #

@pytest.mark.tier1
def test_finalize_columns_dedup():
    """A subclass returning worker_id / claimed_at / the status column in extras
    must not produce 'column specified more than once' — framework columns win
    and each appears once."""
    set_sql, params = base.finalize_columns(
        "cleaner_status", "resolved",
        {"pdl_company_id": "co-1", "worker_id": "leak", "cleaner_status": "leak"})
    # every column appears exactly once
    cols = [s.split(" = ")[0] for s in set_sql]
    assert len(cols) == len(set(cols))
    assert set(cols) == {"pdl_company_id", "cleaner_status", "worker_id", "claimed_at"}
    # framework values win over the leaked extras
    d = dict(zip(cols, params, strict=True))
    assert d["cleaner_status"] == "resolved"
    assert d["worker_id"] is None and d["claimed_at"] is None
    assert d["pdl_company_id"] == "co-1"


@pytest.mark.tier1
def test_reclaim_stale_clamps_fractional_minutes(mock_conn):
    """stale_minutes < 1 must not floor to 0 (which would reclaim rows still
    being processed). 0.5 -> '1 minutes'."""
    mock_conn.cursor.return_value.rowcount = 0
    base.reclaim_stale_simple(mock_conn, "pdl_api.q", "cleaner_status", 0.5)
    _sql, params = mock_conn.cursor.return_value.execute.call_args.args
    assert params == ("1 minutes",)


# ------------------------------ PDLCaller ----------------------------- #

@pytest.mark.tier1
def test_claim_uses_skip_locked_and_status_column(mocker, mock_conn):
    """_claim issues FOR UPDATE SKIP LOCKED on the driver view and flips the
    subclass's queue_status_column to in_progress."""
    mock_conn.cursor.return_value.fetchall.return_value = []
    _FakeCaller()._claim(mock_conn, "w", 10)
    sql = mock_conn.cursor.return_value.execute.call_args.args[0]
    assert "FOR UPDATE SKIP LOCKED" in sql
    assert "pdl_api.v_fake_input" in sql
    assert "cleaner_status = 'in_progress'" in sql


@pytest.mark.tier1
def test_process_batch_returns_early_when_credit_cap_spent(mocker, mock_conn):
    """With the day's cap already spent, process_batch does no claim / no call."""
    caller = _FakeCaller(credit_cap_per_day=5, credit_cap_per_month=None)
    mocker.patch.object(base, "credits_spent_today", return_value=5)
    claim = mocker.patch.object(caller, "_claim")
    call = mocker.patch(_PDL_API_CALL_PATCH)
    n = caller.process_batch(mock_conn, "w", limit=10)
    assert n == 0
    claim.assert_not_called()
    call.assert_not_called()


@pytest.mark.tier1
def test_process_batch_sends_bare_payload_no_metadata(mocker, mock_conn):
    """Single-record cleaners send the bare driver-view payload — no metadata
    field on the wire — and thread worker_id into the finalize."""
    caller = _FakeCaller()
    mocker.patch.object(base, "cap_reached", return_value=False)
    mocker.patch.object(caller, "_claim", return_value=[
        {"input_list_id": 7, "request_payload": {"location": "x"}}])
    rec = mocker.patch.object(caller, "_record_and_finalize")
    call = mocker.patch(_PDL_API_CALL_PATCH, return_value=_pdl_result(200, {"name": "a"}))
    caller.process_batch(mock_conn, "w")
    payload = call.call_args.args[1]
    assert payload == {"location": "x"}       # bare, no metadata key added
    assert "metadata" not in payload
    rec.assert_called_once()
    # _record_and_finalize(conn, worker_id, input_list_id, ...)
    assert rec.call_args.args[1] == "w" and rec.call_args.args[2] == 7


@pytest.mark.tier1
def test_record_and_finalize_guarded_one_transaction(mock_conn):
    """The queue UPDATE is guarded (worker_id + still in_progress); when
    we own the row (rowcount==1) the audit INSERT + finalize commit together."""
    mock_conn.cursor.return_value.rowcount = 1
    caller = _FakeCaller()
    caller._record_and_finalize(mock_conn, "w", 7, {"location": "x"},
                                _pdl_result(200, {"name": "a"}), "resolved", {})
    calls = [c.args[0] for c in mock_conn.cursor.return_value.execute.call_args_list]
    upd = next(s for s in calls if "UPDATE pdl_api.fake_input_list" in s)
    assert "worker_id = %s" in upd and "cleaner_status = 'in_progress'" in upd
    assert any(s.strip().startswith("INSERT INTO pdl_api.fake_call") for s in calls)
    mock_conn.commit.assert_called_once()


@pytest.mark.tier1
def test_record_and_finalize_skips_audit_when_row_lost(mock_conn):
    """If a reclaim handed the row to another worker (UPDATE matches 0),
    roll back and write NO audit row (our result is superseded)."""
    mock_conn.cursor.return_value.rowcount = 0
    caller = _FakeCaller()
    caller._record_and_finalize(mock_conn, "w", 7, {"location": "x"},
                                _pdl_result(200, {"name": "a"}), "resolved", {})
    calls = [c.args[0] for c in mock_conn.cursor.return_value.execute.call_args_list]
    assert not any("INSERT INTO" in s for s in calls)   # no audit on a lost race
    mock_conn.rollback.assert_called_once()
    mock_conn.commit.assert_not_called()


@pytest.mark.tier1
def test_reclaim_stale_requeues_in_progress(mock_conn):
    """Single-record reclaim flips stale in_progress back to pending."""
    mock_conn.cursor.return_value.rowcount = 3
    n = _FakeCaller().reclaim_stale(mock_conn, stale_minutes=15)
    sql = mock_conn.cursor.return_value.execute.call_args.args[0]
    assert "cleaner_status = 'pending'" in sql
    assert "cleaner_status = 'in_progress'" in sql
    assert n == 3


# ---------------------------- BulkPDLCaller --------------------------- #

class _FakeBulk(BulkPDLCaller):
    def __init__(self, **kw):
        super().__init__(
            endpoint_url="/v5/fake/enrich/bulk",
            driver_view="pdl_api.v_fake_enrich",
            queue_table="pdl_api.fake_input_list",
            queue_status_column="enrichment_status",
            audit_table="pdl_api.fake_enrich_call",
            rate_limit_rpm=kw.get("rate_limit_rpm", 0),
            credit_cap_per_day=kw.get("credit_cap_per_day"),
            credit_cap_per_month=kw.get("credit_cap_per_month"),
        )

    def build_bulk_payload(self, rows):
        return {"requests": [{"metadata": {"input_list_id": r["id"]}} for r in rows]}

    def map_bulk_response(self, result, rows):
        return [(r["id"], "enriched", {}) for r in rows]

    def _claim(self, conn, worker_id, limit, source_list):
        return [{"id": 1}]

    def _record_batch(self, conn, batch_id, claimed, result):
        pass


@pytest.mark.tier1
def test_bulk_is_not_a_pdlcaller_subclass():
    """Siblings, not one hierarchy — no LSP violation by construction."""
    assert not issubclass(BulkPDLCaller, PDLCaller)
    assert not issubclass(PDLCaller, BulkPDLCaller)


@pytest.mark.tier1
def test_bulk_process_batch_consults_credit_cap(mocker, mock_conn):
    """The credit cap on the billed bulk endpoint is checked in process_batch
    before any claim or HTTP call."""
    caller = _FakeBulk(credit_cap_per_day=100, credit_cap_per_month=None)
    mocker.patch.object(base, "credits_spent_today", return_value=100)
    claim = mocker.patch.object(caller, "_claim")
    call = mocker.patch(_PDL_API_CALL_PATCH)
    n = caller.process_batch(mock_conn, "w", limit=100)
    assert n == 0
    claim.assert_not_called()
    call.assert_not_called()


@pytest.mark.tier1
def test_bulk_process_batch_rejects_over_cap():
    """limit above the per-call bulk cap fails before any DB work."""
    with pytest.raises(ValueError, match="exceeds PDL bulk cap"):
        _FakeBulk().process_batch(object(), "w", limit=101)
