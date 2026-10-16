# PDL API — Generic Caller Framework

**Status:** Implemented (`processing/pdl_api/`).
**Companion docs:**
- [`16_dbt_pipeline_layers.md`](16_dbt_pipeline_layers.md) — layer model; `pdl_api.*` is the stateful API cache the staging tier reads from.
- [`15_pdl_staging_design.md`](15_pdl_staging_design.md) — PDL Person staging, the main source of `pdl_company_id`s to enrich.
- [`common_libraries.md`](common_libraries.md) — `processing.common.pdl` (HTTP + retry wrapper) and `processing.common.db`.
- [`../data_model/08_company.md`](../data_model/08_company.md) — how enrichment responses land in `integration.company`.
- Schema: `modeling/dbml/pdl_api.dbml`; migrations `V3__pdl_api_company_enrichment.sql`, `V35__pdl_api_location_cleaner.sql`, `V36__pdl_api_school_cleaner.sql`.

---

## Contents

- [Motivation](#motivation)
- [Scope — 4 endpoints, 2 patterns](#scope--4-endpoints-2-patterns)
- [Architecture — data flow](#architecture--data-flow)
- [Queue tables (`pdl_api.*_input_list`)](#queue-tables-pdl_api_input_list)
- [Driver views (`pdl_api.v_*_input*`)](#driver-views-pdl_apiv__input)
- [Audit tables (`pdl_api.*_call`)](#audit-tables-pdl_api_call)
- [`PDLCaller` + `BulkPDLCaller` — sibling base classes](#pdlcaller-single-record--bulkpdlcaller-bulk--sibling-base-classes)
- [Dedup + provenance](#dedup--provenance)
- [Queue population](#queue-population)
- [Rate limits + credit caps](#rate-limits--credit-caps)
- [Failure handling + retry](#failure-handling--retry)
- [Running the callers + pipeline decoupling](#running-the-callers--pipeline-decoupling)
- [Concrete workflow — cleaner + enrichment passes](#concrete-workflow--cleaner--enrichment-passes)
- [Generated columns — response identifier extraction](#generated-columns--response-identifier-extraction)
- [Module layout](#module-layout)

---

## Motivation

Four PDL endpoints share the same `claim → call → audit → finalize` machinery: company enrichment plus the company, location and school cleaners. Writing each as its own driver would mean duplicating the pipeline code and letting the copies drift as safeguards (credit caps, crash recovery, retry bounds) evolve.

**Solution**: the shared machinery lives in two generic base classes in `processing/pdl_api/base.py`. Each endpoint is a small subclass that supplies its table names, rate limit and response mapping.

## Scope — 4 endpoints, 2 patterns

| Endpoint | Pattern | Purpose | Module |
| -------- | ------- | ------- | ------ |
| `/v5/company/clean` | Cleaner (single-record) | Company name / website → `pdl_company_id` | `company_cleaner.py` |
| `/v5/company/enrich/bulk` | Enrichment (bulk, billed) | `pdl_company_id` → full company record | `company_enrichment.py` |
| `/v5/location/clean` | Cleaner (single-record) | Free-text location → canonical PDL location name | `location_cleaner.py` |
| `/v5/school/clean` | Cleaner (single-record) | Free-text school name → `pdl_school_id` | `school_cleaner.py` |

**PDL Person data does not need cleaning.** PDL Person deliveries already carry canonical company / school / location values and ids. The cleaners exist for inputs that are *not* already in PDL's vocabulary — e.g. a hand-assembled company list (name + website), or free-text school and location strings — so they can be resolved to PDL identifiers and joined to PDL data.

**Enrichment is different**: its input is a `pdl_company_id` (either discovered in PDL Person data or resolved by the company cleaner). Its output is the full company record, which feeds `staging.pdl_api_company_parsed` → `integration.company`.

## Architecture — data flow

```
Inputs (company lists, pdl_company_ids from PDL Person data, free-text
location / school strings)
  │
  │  queue population — INSERT into the queue table (dedup on its natural key)
  ▼
pdl_api.<domain>_input_list                      ← QUEUE TABLE (stateful)
  columns: id, <natural key>, <status column(s)> (CHECK enum),
           worker_id, claimed_at, created_at
  │
  │  driver view projects a normalized shape
  ▼
pdl_api.v_<domain>_input[_for_<pass>]            ← DRIVER VIEW
  columns: input_list_id, endpoint, request_payload
  filtered to <status> = 'pending'
  │
  │  framework: SKIP LOCKED claim → build payload → PDL call →
  │             map status → INSERT audit → UPDATE queue status
  ▼
pdl_api.<domain>_<pass>_call                     ← AUDIT TABLE (append-only)
  columns: id, input_list_id FK, endpoint, request_json, response_json,
           response_status, called_at, latency_ms, error_message
           + generated cols extracting response identifiers
  │
  │  dbt reads audit rows (stateless rebuild)
  ▼
staging.pdl_api_company_parsed  →  integration.company (+ company_affiliation)
```

The only dbt consumer is the enrichment path (`company_enrichment_call` → `staging.pdl_api_company_parsed`). The cleaner audit tables are declared as dbt sources (`processing/dbt/models/sources.yml`) and are joined back to their inputs on the queue's natural key when a downstream model needs them (see [Dedup + provenance](#dedup--provenance)).

Two things live in the `pdl_api` schema (both stateful, never rebuilt):
1. **Queue tables** — memoize "what we've asked PDL about" and track per-row state.
2. **Audit tables** — persist every PDL call's request + response.

## Queue tables (`pdl_api.*_input_list`)

One per domain. Location and school share the same shape:

```sql
CREATE TABLE pdl_api.location_input_list (
  id              bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  raw_input       text         NOT NULL UNIQUE,       -- natural key for dedup
  cleaner_status  text         NOT NULL DEFAULT 'pending',
  worker_id       text,
  claimed_at      timestamptz,
  created_at      timestamptz  NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT location_cleaner_status_check CHECK (
    cleaner_status IN ('pending', 'in_progress', 'resolved', 'not_found', 'error')
  )
);
```

**The company queue is different** — `pdl_api.company_input_list` serves BOTH `/v5/company/clean` and `/v5/company/enrich/bulk`, so it carries two status columns and a richer input shape:

| Column | Purpose |
|---|---|
| `source_list` | Provenance label for the list a row came from (e.g. `'top_companies'`, `'person_derived'`). Enrichment runs can be scoped to one list. |
| `pdl_search_params` | PDL request body for matching: `{"name": ..., "website": ...}` when unresolved, or `{"id": "<pdl_company_id>"}` when pre-resolved. |
| `passthrough_params` | Free-form caller correlation data, echoed back via PDL's per-record `metadata`. |
| `pdl_company_id` | NULL until the cleaner resolves it, or pre-populated when the id is already known. |
| `cleaner_status` | `pending` / `not_needed` / `in_progress` / `resolved` / `not_found` / `error` |
| `enrichment_status` | `pending` / `in_progress` / `enriched` / `not_found` / `error` / `skipped_already_enriched` |

A row with an unknown id moves through `cleaner_status: pending → resolved` (the cleaner writes `pdl_company_id` onto the row), then `enrichment_status: pending → enriched`. A row inserted with `pdl_company_id` already set uses `cleaner_status = 'not_needed'` and goes straight to enrichment. The base classes take `queue_status_column` as a per-subclass parameter to accommodate the two columns.

The same `pdl_company_id` may appear on several rows (the same company on two lists); only the first to finish enrichment is billed — the rest are marked `skipped_already_enriched`.

**State machine** (per status column):

```
pending  ─── worker claims ──→  in_progress
                                    │
                                    ├── successful PDL call ──→  resolved / enriched
                                    ├── PDL 404 (no match)   ──→  not_found
                                    └── unrecoverable error  ──→  error

in_progress + stale claimed_at ──→ pending        (reclaim_stale)
error + attempts < max_attempts ──→ pending       (requeue_retryable)
```

**Deduplication invariant** (location / school): `UNIQUE(raw_input)` — the same string from multiple inputs = one queue row.

## Driver views (`pdl_api.v_*_input*`)

Thin projection over the queue table. Standardized column names so the framework doesn't know which endpoint it's serving:

```sql
CREATE VIEW pdl_api.v_location_input AS
SELECT id                                        AS input_list_id,
       '/v5/location/clean'                      AS endpoint,
       jsonb_build_object('location', raw_input) AS request_payload
FROM   pdl_api.location_input_list
WHERE  cleaner_status = 'pending';
```

| View | Filter | `request_payload` |
|---|---|---|
| `v_company_input_for_cleaner` | `cleaner_status = 'pending' AND pdl_company_id IS NULL` | `pdl_search_params` |
| `v_company_input_for_enrichment` | `enrichment_status = 'pending' AND pdl_company_id IS NOT NULL` | `{"id": pdl_company_id}` |
| `v_location_input` | `cleaner_status = 'pending'` | `{"location": raw_input}` |
| `v_school_input` | `cleaner_status = 'pending'` | `{"name": raw_input}` |

**Why a view rather than direct table access**: keeps subclass code out of queue-table column names. If the queue schema changes, the view is the only place that needs to follow. Small hedge; costs one migration line per endpoint.

## Audit tables (`pdl_api.*_call`)

Append-only. One row per PDL call (or, for bulk, per record in the response).

```sql
CREATE TABLE pdl_api.location_cleaner_call (
  id               bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  input_list_id    bigint        NOT NULL REFERENCES pdl_api.location_input_list (id),
  endpoint         text          NOT NULL,
  request_json     jsonb         NOT NULL,
  response_status  smallint,
  response_json    jsonb,
  called_at        timestamptz   NOT NULL DEFAULT clock_timestamp(),
  latency_ms       int,
  error_message    text,
  -- Endpoint-specific generated column (extracted from response_json)
  cleaned_location text          GENERATED ALWAYS AS (response_json->>'name') STORED
);
```

Generated columns vary per endpoint — see [Generated columns](#generated-columns--response-identifier-extraction). PDL-level "no match" is `response_status = 404`, not `error_message`.

**Bulk endpoints** (company enrichment) additionally carry `bulk_batch_id` (from `pdl_api.company_enrichment_batch_seq`) grouping all rows from the same HTTP call. Single-record cleaners don't need it.

## `PDLCaller` (single-record) + `BulkPDLCaller` (bulk) — sibling base classes

The framework has **two sibling base classes**, one per HTTP pattern. They do NOT share an inheritance chain. They DO share helpers (rate limiter, credit-cap checks, pending count, stale reclaim, retry requeue) via module-level functions in `processing/pdl_api/base.py`, and both call PDL through `processing.common.pdl.call_pdl_with_retry`.

- **`PDLCaller`** — single-record cleaners (`/v5/company/clean`, `/v5/location/clean`, `/v5/school/clean`). One HTTP call per queue row. Subclasses override `map_status` (and `build_payload` only if the view's `request_payload` isn't the body as-is).
- **`BulkPDLCaller`** — bulk enrichment (`/v5/company/enrich/bulk`). One HTTP call carries up to 100 queue rows; per-record results reconciled via `metadata.input_list_id`. Subclasses override `build_bulk_payload` + `map_bulk_response`, plus the queue-specific data-access hooks (`_claim`, `_next_batch_id`, `_record_batch`, `_skip_siblings`, `reclaim_stale`). The base owns the orchestration (cap checks, claim → call → record → finalize ordering, pacing) — a template-method base.

**Why two classes instead of one hierarchy?** The single-record and bulk shapes differ in what a "batch" is (one row vs. many rows per HTTP call), how responses are reconciled (direct vs. per-record via metadata), how `reclaim_stale` interacts with billing (cheap retry vs. replay-from-audit to avoid double-charging), and what `process_batch` naturally accepts. Forcing both into one hierarchy produces a facade where the bulk subclass overrides every method of the single-record base — mismatched signatures and return types, and silently-ignored constructor parameters. Siblings avoid that by construction.

### `PDLCaller` — single-record cleaner base

```python
# processing/pdl_api/base.py

class PDLCaller:
    def __init__(
        self, *,
        endpoint_url: str,        # e.g. "/v5/location/clean"
        driver_view: str,         # e.g. "pdl_api.v_location_input"
        queue_table: str,         # e.g. "pdl_api.location_input_list"
        queue_status_column: str, # e.g. "cleaner_status"
        audit_table: str,         # e.g. "pdl_api.location_cleaner_call"
        rate_limit_rpm: int,
        credit_cap_per_day: int | None = None,       # None = no daily cap
        credit_cap_per_month: int | None = 900_000,  # 90% of PDL's 1M/mo per-endpoint cap; None disables
    ): ...

    def build_payload(self, claimed_row) -> dict:
        """Default: return claimed_row["request_payload"] (shaped by the driver view)."""

    def map_status(self, response) -> tuple[str, dict]:
        """Subclass override: (terminal_queue_status, extra_queue_columns).
           Status must satisfy the queue's CHECK constraint; extras are written
           onto the queue row alongside it (e.g. pdl_company_id)."""
        raise NotImplementedError

    def process_batch(self, conn, worker_id, limit=100, *, sleep_fn=time.sleep) -> int:
        """Do NOT override.
           1. Return 0 early if a credit cap is already spent
           2. SKIP LOCKED claim up to `limit` rows from the driver view →
              in_progress + worker_id + claimed_at
           3. Per row: rate-limit wait → build_payload → call_pdl_with_retry → map_status
           4. Guarded queue UPDATE + audit INSERT in ONE transaction per row
           Returns rows processed."""

    def drain(self, conn, worker_id, *, batch_limit=100, sleep_fn=time.sleep) -> int:
        """reclaim_stale first (crash recovery), then loop process_batch until the
           driver view is empty. One RateLimiter shared across batches."""

    def reclaim_stale(self, conn, stale_minutes=15) -> int: ...
    def requeue_retryable(self, conn, max_attempts=3) -> int: ...
```

The per-row finalize is **guarded**: the queue UPDATE only fires if this worker still owns the row and it is still `in_progress`. If a stale-reclaim handed the row to another worker while the PDL call was in flight, the UPDATE matches 0 rows, the transaction rolls back and no audit row is written (the result is superseded; auditing it would inflate the retry-attempt count).

### `BulkPDLCaller` — bulk-batched base

```python
class BulkPDLCaller:
    def __init__(
        self, *,
        endpoint_url: str,        # "/v5/company/enrich/bulk"
        driver_view: str,
        queue_table: str,
        queue_status_column: str,
        audit_table: str,
        rate_limit_rpm: int,
        credit_cap_per_day: int | None = None,
        credit_cap_per_month: int | None = 900_000,
        max_batch_size: int = 100,               # PDL's per-HTTP-call cap
    ): ...

    def build_bulk_payload(self, claimed_rows) -> dict:
        """Subclass override: JSON body for one bulk call. Must include
           per-record metadata.input_list_id."""

    def map_bulk_response(self, result, claimed_rows) -> list[tuple[int, str, dict]]:
        """Subclass override: [(input_list_id, new_status, extras), ...].
           Reconcile by metadata.input_list_id — never by order (PDL may reorder)."""

    def process_batch(self, conn, worker_id, limit=100, *, source_list=None, sleep_fn=time.sleep) -> int:
        """Raises ValueError if limit > max_batch_size. Claim → ONE bulk call →
           _record_batch (commit) → map_bulk_response → _finalize_batch (commit)
           → _skip_siblings."""

    def drain(self, conn, worker_id, *, source_list=None, sleep_fn=time.sleep) -> int: ...
    def reclaim_stale(self, conn, stale_minutes=15, source_list=None) -> tuple[int, int]:
        """(rows_replayed_from_saved_audit, rows_requeued_no_audit). Base default
           is a safe no-op; the enrichment subclass overrides it."""
    def requeue_retryable(self, conn, max_attempts=3) -> int: ...
```

Bulk persists the whole response **before** finalizing the queue (two transactions, in that order). That ordering is what makes a mid-batch crash non-double-charging — `reclaim_stale` replays the saved response onto the stuck queue rows instead of re-calling PDL. `_finalize_batch` is a single `execute_values` UPDATE (not a per-row loop), guarded on `worker_id` + `in_progress` like the single-record path.

### Subclasses

- **`CompanyCleanerCaller`, `LocationCleanerCaller`, `SchoolCleanerCaller`** — inherit from `PDLCaller`. Each overrides only `map_status`. `CompanyCleanerCaller` returns `{"pdl_company_id": ...}` as extras so the resolved id is written back onto the queue row (the enrichment view keys off it); location and school write nothing back.
- **`CompanyEnrichmentCaller`** — inherits from `BulkPDLCaller`. Sends `{"params": {"pdl_id": ...}, "metadata": {"input_list_id": ..., **passthrough_params}}` per record; maps 200 → `enriched`, 404 → `not_found`, anything else (including a dropped or truncated slot) → `error`.

### Example single-record subclass

```python
# processing/pdl_api/school_cleaner.py

class SchoolCleanerCaller(PDLCaller):
    def __init__(self, *, rate_limit_rpm=DEFAULT_SCHOOL_CLEANER_RPM, credit_cap_per_day=None):
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
        status, body = response["http_status"], response["body"]
        if status == 200 and isinstance(body, dict) and body.get("id"):
            return "resolved", {}
        if status in (200, 404):          # 200 with no id is a no-match too
            return "not_found", {}
        return "error", {}                # 5xx / exhausted retries → retryable
```

`LocationCleanerCaller.map_status` gates on `body.get("name")` instead of `id` — `/v5/location/clean` returns no top-level id; the canonical value is the composite name (e.g. `"austin, texas, united states"`).

Adding a new single-record endpoint: one ~50-line subclass + the queue / audit / view trio in a Flyway migration + DBML. Framework code is untouched.

## Dedup + provenance

**Dedup** — location / school queues are keyed on `UNIQUE(raw_input)`; populate with `INSERT ... ON CONFLICT (raw_input) DO NOTHING`. The same string arriving from several inputs = one queue row = one PDL call. The company queue dedups at enrichment time instead (sibling skip on `pdl_company_id`).

**PDL metadata** — only the bulk path sends `metadata.input_list_id`, because bulk responses must be reconciled per record and PDL may reorder them. Single-record cleaners do not send metadata: each call handles one row whose id is known locally, and keeping it out of the body avoids strict-validation errors on `/v5/*/clean`. The full request body is preserved in the audit table's `request_json` either way.

**Provenance — reconstructed on demand, not stored.** Which inputs contributed a given `raw_input` is derivable by joining the input tables to the queue on `raw_input`. The mapping isn't cached on the queue row because:

- Downstream models already do this join anyway (see below).
- Caching creates a merge-policy question (append vs replace when a new input contributes the same string) with no downstream consumer.
- The queue row is about "what did we ask PDL," not "who wanted it asked."

**Fan-out to input rows** — a downstream model joins by `raw_input`:

```sql
SELECT
  src.id,
  src.school_name          AS raw_school,
  scc.pdl_school_id,
  scc.response_json->>'name' AS canonical_school_name
FROM <input_table> src
JOIN pdl_api.school_input_list  sil ON sil.raw_input     = src.school_name
JOIN pdl_api.school_cleaner_call scc ON scc.input_list_id = sil.id
WHERE sil.cleaner_status = 'resolved'
  AND scc.response_status = 200;
```

One PDL call fans out to many input rows via the natural-key JOIN. Such models are stateless (rebuilt on every run).

## Queue population

Queue rows are inserted ahead of a drain; inserts are idempotent on the natural key, and existing rows (whatever their status) are never touched:

- **Company** — insert one row per company on a list, tagged with a `source_list`. Rows with a known `pdl_company_id` (e.g. the most frequent companies in `staging.pdl_person_companies_unique`) are inserted pre-resolved with `cleaner_status = 'not_needed'`; rows with only name / website start at `cleaner_status = 'pending'`.
- **Location / school** — `INSERT ... SELECT DISTINCT <field> ... ON CONFLICT (raw_input) DO NOTHING` from whatever table holds the free-text values. There is no dbt queue-population model; one can be added per input table when needed (incremental, append, filtered on `raw_input NOT IN (SELECT raw_input FROM {{ this }})`).

Re-running population on the same inputs is a no-op; in-flight (`in_progress`) and finished (`resolved`, `enriched`, `not_found`) rows stay as they are.

## Rate limits + credit caps

**PDL's rate limits** vary by plan; confirm yours in the PDL dashboard or the `/v5/*/clean` response headers. Limits of one plan, for illustration:

| Endpoint | Per-minute cap | Per-month cap | Per-call billed? |
|---|---:|---:|---|
| `/v5/company/clean` | 10,000 rpm | 1,000,000 / month | No |
| `/v5/location/clean` | 10,000 rpm | 1,000,000 / month | No |
| `/v5/school/clean` | 10,000 rpm | 1,000,000 / month | No |
| `/v5/company/enrich/bulk` | 1,000 rpm × up to 100 records per call | per-credit; billed | Yes |

Cleaners don't consume enrichment credits, but they DO count against per-endpoint per-minute + per-month caps.

**Framework knobs** (on both base classes):
- **`rate_limit_rpm`** — sustained pace the worker targets, enforced by a `RateLimiter` shared across batches within one `drain()`. Defaults: `60` for each cleaner (`DEFAULT_CLEANER_RPM`, `DEFAULT_LOCATION_CLEANER_RPM`, `DEFAULT_SCHOOL_CLEANER_RPM`), `10` bulk calls/min for enrichment (`DEFAULT_BULK_ENRICH_RPM`, i.e. up to 1,000 records/min). Conservative floors meant to fit any plan; override with the value PDL grants. `0` disables pacing.
- **`credit_cap_per_day`** — optional per-day billing stop; counts successful (`response_status = 200`) audit rows with `called_at::date = current_date`. `None` by default for every endpoint.
- **`credit_cap_per_month`** — per-month request stop; defaults to `900_000` (90% of PDL's 1M monthly ceiling per endpoint). Counts **all** audit rows with `called_at >= date_trunc('month', now())`, whatever the status — PDL's monthly ceiling counts every request (200s, 404s, errors), not just successes. Applies to cleaners + enrichment.

`process_batch` checks caps before claiming, so a spent cap returns 0 without touching the queue.

For paid enrichment runs, `run_enrichment(conn, worker_id, source_list, *, max_credits, ...)` in `company_enrichment.py` adds a per-run credit budget on top: it clamps each batch so the run cannot overshoot `max_credits`, reclaims stale rows first, and requeues retryable errors (bounded by `max_attempts`) once the pending queue is empty.

### One drainer per endpoint

Run at most one drainer per endpoint at a time. Multiple inputs can push into the same queue concurrently; the drainer reads them uniformly, and per-endpoint rate limits are respected without cross-worker coordination. (`SKIP LOCKED` claims make concurrent drainers *safe*, just not rate-limit-aware.)

### Cross-endpoint coordination

An account-wide throttle across endpoints is not implemented — `processing.common.pdl` has reactive 429 handling (honoring `Retry-After`, otherwise jittered exponential backoff). With the defaults (3 cleaners × 60 rpm = 180 rpm) this is far below PDL's limits. Revisit only if real usage approaches the account cap.

### Retry storms on 404s

`map_status` marks 404 (and 200-with-no-match) as terminal `not_found`, never retried. Any revisit is an explicit operator decision (`UPDATE <queue> SET cleaner_status = 'pending' WHERE ...`). Prevents unbounded per-input retry loops.

## Failure handling + retry

**Per-call failure modes:**
- **HTTP 200 with a match**: `resolved` / `enriched`.
- **HTTP 404, or 200 without a match**: `not_found`. Not retried.
- **HTTP 429 / 502 / 503 / 504, network errors, timeouts**: retried inside `call_pdl_with_retry` (up to 5 retries after the first attempt; `Retry-After` honored, else jittered exponential backoff capped at 60 s). If retries are exhausted, the last result is audited and the row is marked `error`.
- **Other 4xx** (auth, malformed request): returned on the first call, audited, row marked `error`.

**Bounded retry of `error` rows**: `requeue_retryable(conn, max_attempts=3)` flips `error` rows back to `pending` while the row has fewer than `max_attempts` audit rows. `not_found` stays terminal.

**Worker crashes mid-batch**:
- `PDLCaller.reclaim_stale(conn, stale_minutes=15)` — resets `in_progress` rows with a stale `claimed_at` back to `pending`. Safe for cleaners (each row's audit + finalize commit atomically, so there is never a saved-but-unfinalized result).
- `CompanyEnrichmentCaller.reclaim_stale(...)` — bulk-specific: first replays completed audit rows onto their stuck queue rows (finishing half-committed work without re-charging PDL), then requeues the rest. Returns `(replayed_from_audit, requeued)`. A plain reclaim on the billed bulk endpoint would double-charge on every crash + restart.
- Every `drain()` calls `reclaim_stale` before its batch loop, so a crashed run self-recovers on the next run.

**Queue rows are never deleted.** To reprocess a row (e.g. PDL improved its cleaner), set its status back to `pending` explicitly.

## Running the callers + pipeline decoupling

Each cleaner module is a CLI:

```bash
python -m processing.pdl_api.company_cleaner  drain [--rpm N]
python -m processing.pdl_api.location_cleaner drain [--rpm N]
python -m processing.pdl_api.school_cleaner   drain [--rpm N]
```

They connect via `processing.common.db.connect()` (`DATABASE_URL`, or libpq `PG*` vars) and read `PDL_API_KEY` from the environment. Run them on the host in the `pdl_test` conda env. They have no interactive confirm, so they can run unattended. `--rpm` overrides the default pace without a code change — e.g. a one-time backfill of a large school queue can run with `--rpm 500` and later runs drop back to the default.

Company enrichment is **operator-triggered** because it is billed. It always runs for one `source_list` with an explicit credit budget:

```bash
python -m processing.pdl_api.company_enrichment run --source-list <list> --max-credits N [--rpm N]
# or: make enrich-pdl SOURCE_LIST=<list> MAX_CREDITS=N
```

The CLI wraps `run_enrichment(...)`, which can also be called from Python. `make clean-pdl` drains all three cleaner queues. Both make targets refuse to start without `PDL_API_KEY`. `python -m processing.pdl_api.company_enrichment` with no arguments runs a small live demo (seeds two rows under `source_list = 'demo_list'`, runs both passes, prints the tables) and refuses to start unless `PDL_DEMO_CONFIRM=1` is set.

The API callers and the dbt rebuild are **operationally decoupled** via the audit tables:

```
   Operator populates a queue                              make dbt-pdl / pipeline-pdl
              │                                                       │
              ▼                                                       ▼
   pdl_api callers drain it                                    dbt rebuild
              │                                                       │
              ▼                                                       ▼
   pdl_api.*_call (audit tables)          ──read──>     staging.pdl_api_company_parsed
                                                                      │
                                                                      ▼
                                                               integration.*
```

Three invariants:

1. **Audit is append-only and persistent.** `pdl_api.*_call` accumulates whatever was fetched. No TTL.
2. **Staging rebuilds deterministically from audit + raw on every dbt run.** `staging.pdl_api_company_parsed` always reflects the current audit contents — nothing else.
3. **Integration rebuilds from staging on every dbt run.** Stateless. Same staging inputs → same integration outputs.

Consequence: **no new API calls since the last dbt run → identical output.** If the callers aren't run for months, the next dbt run still works from the still-current audit set. No coupling between when enrichment runs and when the pipeline runs.

## Concrete workflow — cleaner + enrichment passes

### Cleaner pass (single-record; company / location / school)

```
1. WITH picked AS (
     SELECT input_list_id, request_payload FROM pdl_api.v_<domain>_input
     ORDER BY input_list_id FOR UPDATE SKIP LOCKED LIMIT N)
   UPDATE pdl_api.<domain>_input_list
   SET cleaner_status = 'in_progress', worker_id = $me, claimed_at = clock_timestamp()
   FROM picked WHERE id = picked.input_list_id
   RETURNING ...;                                              -- commit

2. For each claimed row (paced by the RateLimiter):
     result := call_pdl_with_retry(<endpoint>, request_payload)
     (status, extras) := map_status(result)
     BEGIN;
       UPDATE pdl_api.<domain>_input_list
       SET cleaner_status = status, <extras>, worker_id = NULL, claimed_at = NULL
       WHERE id = $id AND worker_id = $me AND cleaner_status = 'in_progress';
       -- rowcount 0 → ROLLBACK, skip audit (superseded by a reclaim)
       INSERT INTO pdl_api.<domain>_cleaner_call (...);
       -- generated identifier column populates automatically
     COMMIT;
```

Downstream models read the canonical identifier from the audit table, not the queue — except for the company cleaner, which also writes `pdl_company_id` onto the queue row so the enrichment view can pick it up.

### Enrichment pass (bulk; up to 100 per HTTP call)

```
1. Claim up to 100 rows from pdl_api.v_company_input_for_enrichment
   (optionally scoped to one source_list), FOR UPDATE SKIP LOCKED
   → enrichment_status = 'in_progress', worker_id, claimed_at        -- commit

2. $batch := nextval('pdl_api.company_enrichment_batch_seq')
   POST /v5/company/enrich/bulk with one request per row:
     {"params": {"pdl_id": ...}, "metadata": {"input_list_id": id, ...passthrough}}

3. INSERT one pdl_api.company_enrichment_call row per claimed record,
   matched by metadata.input_list_id, all sharing bulk_batch_id = $batch   -- commit

4. UPDATE pdl_api.company_input_list (single execute_values statement)
   SET enrichment_status = enriched | not_found | error,
       worker_id = NULL, claimed_at = NULL
   WHERE id = v.id AND worker_id = $me AND enrichment_status = 'in_progress'  -- commit

5. Sibling skip — other unfinished rows targeting a just-enriched id
   (pending AND in_progress, so a concurrent worker on another source_list
   can't bill the same company twice; its guarded finalize becomes a no-op):
   UPDATE pdl_api.company_input_list
   SET enrichment_status = 'skipped_already_enriched', worker_id = NULL, claimed_at = NULL
   WHERE enrichment_status IN ('pending', 'in_progress')
     AND pdl_company_id IN (SELECT pdl_company_id FROM pdl_api.company_enrichment_call
                            WHERE bulk_batch_id = $batch AND response_status = 200);
```

Writing to `integration.company` is NOT part of this workflow — it happens on the next dbt rebuild.

**Re-enrichment.** Sibling skip is one-way: nothing flips `enriched` / `skipped_already_enriched` rows back. A future refresh job could read PDL's company changelog and reset changed ids to `enrichment_status = 'pending'`; no migration is needed (statuses are reversible, audit is grouped by `bulk_batch_id`). If that is built, `staging.pdl_api_company_unique` (in the DBML, no dbt model) becomes the dedup step between `_parsed` and integration.

## Generated columns — response identifier extraction

Audit tables extract identifiers from `response_json` via PostgreSQL STORED generated columns (hand-authored in the migrations; DBML cannot express GENERATED):

| Audit table | Generated columns |
|---|---|
| `company_cleaner_call` | `pdl_company_id` ← `response_json->>'id'` |
| `company_enrichment_call` | `pdl_company_id` ← `->>'id'`, `pdl_dataset_version` ← `->>'dataset_version'`, `pdl_likelihood` ← `(->>'likelihood')::int` |
| `location_cleaner_call` | `cleaned_location` ← `response_json->>'name'` |
| `school_cleaner_call` | `pdl_school_id` ← `response_json->>'id'` |

Computed once at insert; persisted; indexable; can't drift from the source JSON. The caller never parses — it writes `response_json` and downstream models read the columns. Adding a new extracted field is an `ALTER TABLE ... ADD COLUMN ... GENERATED`, no backfill code. Extraction expressions must be `IMMUTABLE`; pure JSON extraction qualifies.

---

## Module layout

```
processing/pdl_api/
    base.py                  # PDLCaller + BulkPDLCaller + shared helpers (RateLimiter, caps, reclaim, requeue, CLI parsing)
    company_cleaner.py       # CompanyCleanerCaller (/v5/company/clean) + process_cleaner_batch wrapper + drain CLI
    company_enrichment.py    # CompanyEnrichmentCaller (/v5/company/enrich/bulk) + process_enrichment_batch / run_enrichment + demo
    location_cleaner.py      # LocationCleanerCaller (/v5/location/clean) + drain CLI
    school_cleaner.py        # SchoolCleanerCaller (/v5/school/clean) + drain CLI
    tests/                   # unit + integration; PDL HTTP is always mocked (opt-in smoke test is marker-gated)
```

`process_cleaner_batch` / `process_enrichment_batch` are thin module-level wrappers over the class instances, kept as a stable function-style API.
