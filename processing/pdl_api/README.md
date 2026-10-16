# processing/pdl_api/

Pipeline step 3: the generic PDL API caller — **company enrichment** plus the **company, location and school cleaners**. Each caller claims rows from a queue table via a driver view, calls PDL, writes one append-only audit row per call (per record for bulk), and moves the queue row to a terminal status. dbt then parses the audit tables (`staging.pdl_api_company_parsed`) into the `ref` / `integration` model.

Spec: [`docs/design/18_pdl_api_generic_caller.md`](../../docs/design/18_pdl_api_generic_caller.md). Schema lives in the `pdl_api` Postgres schema (`modeling/dbml/pdl_api.dbml`): company tables in `V3__pdl_api_company_enrichment.sql`, location and school in `V35__pdl_api_location_cleaner.sql` and `V36__pdl_api_school_cleaner.sql`.

## Two base classes

- **`PDLCaller`** — single-record cleaners (`/v5/*/clean`). One HTTP call per queue row. Subclasses override `build_payload` + `map_status`.
- **`BulkPDLCaller`** — bulk enrichment (`/v5/company/enrich/bulk`). One HTTP call carries up to 100 rows; per-record results are reconciled via `metadata.input_list_id`. Subclasses override `build_bulk_payload` + `map_bulk_response`.

They share helpers (rate limiter, credit-cap checks, finalize-column building, stale-row reclaim, retry requeue) as module-level functions in `base.py` rather than an inheritance chain: single-record and bulk differ in payload shape (per row vs per batch), reconciliation (direct vs metadata-based) and stale reclaim (idempotent vs replay-from-audit), so one hierarchy would be a leaky abstraction.

| Caller | Endpoint | Queue → audit |
|---|---|---|
| `CompanyCleanerCaller` (`company_cleaner.py`) | `/v5/company/clean` | `pdl_api.company_input_list` → `pdl_api.company_cleaner_call` |
| `CompanyEnrichmentCaller` (`company_enrichment.py`) | `/v5/company/enrich/bulk` | `pdl_api.company_input_list` → `pdl_api.company_enrichment_call` |
| `LocationCleanerCaller` (`location_cleaner.py`) | `/v5/location/clean` | `pdl_api.location_input_list` → `pdl_api.location_cleaner_call` |
| `SchoolCleanerCaller` (`school_cleaner.py`) | `/v5/school/clean` | `pdl_api.school_input_list` → `pdl_api.school_cleaner_call` |

The company pass is a waterfall: rows without a `pdl_company_id` go through the cleaner first; resolved rows (most of them — every PDL person experience already carries a company id) go straight to enrichment.

## Layout

```
pdl_api/
    __init__.py
    base.py                  # PDLCaller + BulkPDLCaller, rate limiter, credit caps, stale reclaim, drain CLI parsing
    company_cleaner.py       # CompanyCleanerCaller + process_cleaner_batch
    company_enrichment.py    # CompanyEnrichmentCaller + process_enrichment_batch / run_enrichment + guarded live demo
    location_cleaner.py      # LocationCleanerCaller
    school_cleaner.py        # SchoolCleanerCaller
    tests/                   # unit + integration (PDL always mocked); test_pdl_smoke.py is opt-in
```

## Running

From the repo root in the `pdl_test` conda env, with the local stack up (`make dev-up`) and `DATABASE_URL` + `PDL_API_KEY` set (see `.env.example`). These calls hit the real PDL API and spend credits.

```bash
# Cleaners: drain the pending queue rows (all three: make clean-pdl)
python -m processing.pdl_api.company_cleaner  drain [--rpm N]
python -m processing.pdl_api.location_cleaner drain [--rpm N]
python -m processing.pdl_api.school_cleaner   drain [--rpm N]

# Company enrichment for one source list, capped at N billed credits
# (same as: make enrich-pdl SOURCE_LIST=x MAX_CREDITS=n)
python -m processing.pdl_api.company_enrichment run --source-list x --max-credits N [--rpm N]

# Then parse the results into staging and rebuild downstream
cd processing/dbt && dbt build --select pdl_api_company_parsed+
```

Company enrichment is driven from Python with an explicit credit cap:

```python
from processing.common.db import connect
from processing.pdl_api.company_enrichment import run_enrichment

conn = connect()            # DATABASE_URL, else PG* env vars
try:
    run_enrichment(conn, worker_id="local", source_list="<your_list>", max_credits=500)
finally:
    conn.close()
```

`run_enrichment` reclaims stale rows, requeues retryable errors, clamps each batch so it can't overshoot `max_credits`, and paces bulk calls at `requests_per_minute`.

`python -m processing.pdl_api.company_enrichment` with no arguments runs a small live demo (seeds two placeholder rows under `source_list = 'demo_list'` — edit them in `_demo()` to look up a real company — runs cleaner + enrichment, prints the queue and audit tables). It refuses to run unless `PDL_DEMO_CONFIRM=1` is set. Its DELETEs are scoped to `demo_list`.

`DATABASE_URL` takes precedence; otherwise libpq's standard `PG*` variables are used (`PGHOST=localhost PGUSER=pdl_etl PGPASSWORD=pdl_etl_dev PGDATABASE=pdl_etl`).

## Writing a new endpoint

Subclass `PDLCaller`, pass the constructor args (endpoint / driver view / queue table / queue-status column / audit table / rpm / daily credit cap), and override `build_payload` (usually returns the view's `request_payload`) and `map_status` (maps the PDL response to a terminal queue status plus any extra queue columns). Add the queue / audit / view trio in a Flyway migration + DBML. `location_cleaner.py` and `school_cleaner.py` are short reference examples. Runtime contract: `python -m processing.pdl_api.<module> drain`.

## Public API

```python
from processing.pdl_api.company_cleaner import process_cleaner_batch, DEFAULT_CLEANER_RPM
from processing.pdl_api.company_enrichment import (
    process_enrichment_batch, run_enrichment, DEFAULT_BULK_ENRICH_RPM,
)
```

- `process_cleaner_batch(conn, worker_id, limit=100, ...)` reads `pdl_api.v_company_input_for_cleaner`, calls `/v5/company/clean` once per claimed row (paced internally), writes `pdl_api.company_cleaner_call`, and sets `cleaner_status` on the queue row.
- `process_enrichment_batch(conn, worker_id, limit=100, *, source_list=None)` reads `pdl_api.v_company_input_for_enrichment`, sends **one** bulk POST with up to `limit` records (hard cap 100 — a larger `limit` raises `ValueError`), writes one `pdl_api.company_enrichment_call` row per record sharing a `bulk_batch_id`, and sets `enrichment_status`. Queue rows whose `pdl_company_id` was already enriched in the same batch are marked `skipped_already_enriched`.

Both return the number of rows processed.

## PDL API limits and caps

Rate limits differ per endpoint and per PDL plan (published tiers are 10, 100, 1,000 or 10,000 requests per minute); check your plan in the PDL dashboard. RPM is therefore set **per caller**, not as one global constant.

| Endpoint | Per-call cap | RPM default |
|---|---|---|
| `/v5/company/clean` | 1 record | `DEFAULT_CLEANER_RPM` = 60 |
| `/v5/location/clean`, `/v5/school/clean` | 1 record | `DEFAULT_LOCATION_CLEANER_RPM` / `DEFAULT_SCHOOL_CLEANER_RPM` = 60 |
| `/v5/company/enrich/bulk` | 100 records per call | `DEFAULT_BULK_ENRICH_RPM` = 10 |

The defaults are conservative floors; override them with your plan's rate. Pass `requests_per_minute=0` to disable throttling when something else is already pacing the calls. Daily / monthly credit caps are checked against the audit tables before each claim.

### Retry behaviour

`processing.common.pdl.pdl_api_call` is the only HTTP-touching function; `call_pdl_with_retry` wraps it:

| Response | Behaviour |
|---|---|
| 200 / 404 / other 4xx | Returned on the first call, no retry (real answers) |
| **429** | Retry up to 5×, honouring `Retry-After` when present; otherwise jittered exponential backoff clamped at 60 s |
| **502 / 503 / 504** | Same retry shape |
| Network error (timeout, reset) | Same retry shape |
| Retries exhausted | Last result returned so it still audits cleanly as `error` |

`sleep_fn` is injectable so tests don't wait through real backoff.

## Refreshing enrichment later (design only)

Sibling skips (`skipped_already_enriched`) are not reversed by anything today — fine for a one-shot backfill. A refresh job would read PDL's company changelog for a window and reset the matching queue rows to `enrichment_status = 'pending'`; the next enrichment pass picks them up with no migration needed. The design keeps that possible: status transitions are reversible, audit tables are append-only and grouped by `bulk_batch_id`, and `worker_id` / `claimed_at` are independent of status.

## Tests

```bash
pytest processing/pdl_api/tests/                        # unit only
DATABASE_URL=<dsn> pytest processing/pdl_api/tests/     # + integration against local Postgres
```

Integration tests skip when `DATABASE_URL` isn't set. PDL HTTP is mocked in every test (see [CLAUDE.md](../../CLAUDE.md)); `test_pdl_smoke.py` is the only exception: it is opt-in (`pytest -m pdl_smoke`), skipped without `PDL_API_KEY`, calls only the company cleaner endpoint, and reads the company to look up from `PDL_SMOKE_COMPANY_NAME` / `_WEBSITE` / `_PROFILE` (see its docstring).

## PDL API key

Read from the `PDL_API_KEY` environment variable only (local `.env`, gitignored). Never commit it.
