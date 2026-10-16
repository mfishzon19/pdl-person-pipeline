# 07. Test Plan

**Audience**: engineers writing or reviewing tests for this pipeline.
**Purpose**: define what is tested, organized by tier, with pytest markers recording which tier each test belongs to. Living document: update it when tests are added, retired, or moved between tiers.

## Ground rules

- **Never call PDL APIs in tests.** Every PDL call is mocked (patch `processing.common.pdl.client.pdl_api_call`). The only exception is the opt-in `pdl_smoke` marker (below), which never runs by default.
- **No AWS credentials or network needed.** S3 reads are mocked (boto3 `get_object` patched to return fixture bytes) or served by the local S3 stand-in (moto server); the default suite must pass offline.
- **Integration tests use local Postgres** from Docker Compose (`make dev-up`), never a shared database.

## Conventions

- **`@pytest.mark.tier1`**: must-have. Catches real correctness bugs.
- **`@pytest.mark.tier2`**: added when code stabilizes. Deeper coverage.
- **`@pytest.mark.tier3`**: full coverage. Worth it only with several contributors and the suite running on every change.
- **`@pytest.mark.integration`**: needs a running Postgres. Auto-skipped unless `DATABASE_URL` is set.
- **`@pytest.mark.pdl_smoke`**: hits the real PDL API. Auto-skipped unless `PDL_API_KEY` is set; run explicitly with `pytest -m pdl_smoke`.

A test can carry a tier marker and `integration` (e.g. `tier1` + `integration`).

Markers are registered in `pyproject.toml` under `[tool.pytest.ini_options]`.

## Status

**Tier 1 is implemented**: every test in the repo carries `tier1`, and the checked items below exist. Unchecked items are gaps. Tier 2 and Tier 3 are inventories of tests not yet written (except where checked).

## File layout

```
processing/s3_ingester/tests/
  conftest.py            — shared fixtures (mock psycopg2 conn, sample configs, integration skip)
  fixtures/              — YAML source configs for _load_source_config tests
    source_partitioned.yaml
    source_flat.yaml
    source_per_partition.yaml
    source_missing_column_list.yaml
    source_invalid_replace.yaml
  test_file_ingester.py
  test_delivery_loader.py
  test_finder.py
  test_integration.py
  smoke_test_local.py    — runnable end-to-end script (NOT pytest)

processing/pdl_api/tests/
  conftest.py            — mock conn / cursor; integration skip
  test_base.py
  test_company_cleaner.py
  test_company_enrichment.py   — also covers call_pdl_with_retry and the rate limiter
  test_location_school_cleaners.py
  test_integration.py
  test_pdl_smoke.py      — live PDL calls, pdl_smoke only

processing/common/{db,aws,preflight}/tests/   — shared-library unit tests
processing/tests/test_logging_setup.py
```

dbt models are tested by dbt itself (`schema.yml` generic tests + singular tests in `processing/dbt/tests/`), run as part of `make dbt-pdl`.

---

## Setup

```bash
conda env create -f environment.yml   # once
conda activate pdl_test
make dev-up                           # postgres + flyway-init + fixture-load
export DATABASE_URL='postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl'
```

For tests or the smoke script that read real objects through the Finder, also run `make dev-up-ingester` (local S3, bucket `pdl-ingest-local`) and set `AWS_ENDPOINT_URL=http://localhost:9000`.

---

## Architecture orientation

Read before writing ingester tests:

1. [`processing/s3_ingester/README.md`](../../processing/s3_ingester/README.md): architecture and implementation walkthrough (three-transaction lifecycle, callback pattern, common failure modes).
2. [`02_pipeline_design.md`](02_pipeline_design.md): S3 Ingester framework, partitioning and `replace_strategy`.
3. The docstring at the top of [`processing/s3_ingester/tests/smoke_test_local.py`](../../processing/s3_ingester/tests/smoke_test_local.py): full run sequence.

Modules under test:

| Module | Public function | What it does |
|---|---|---|
| `finder.py` | `discover_delivery(...)` | Lists the bucket for one delivery; writes `pipeline_run` + `ingestion_run` + N `ingestion_file` rows + `pdl_delivery` |
| `delivery_loader.py` | `load_pending_files(...)` | Per-delivery driver. YAML-driven, optional TRUNCATE of targets (`replace_strategy=full`), per-file calls to `ingest_file`, finalizes `ingestion_run` |
| `file_ingester.py` | `ingest_file(...)` | Per-file primitive. 3-transaction `ingestion_file` status lifecycle around CREATE leaf + ALTER SET DEFAULT + TRUNCATE + `COPY … FROM STDIN` (object fetched with boto3, gunzipped) |
| `pdl_projection_runner.py` | `run_pdl_projection(...)` | Calls `raw.project_pdl_deltas(delivery_date)` and returns its summary |
| `pdl_api/base.py` + callers | `PDLCaller` / `BulkPDLCaller` | Claim queue rows → call PDL → audit → finalize; rate limit, credit cap, retry |

---

## Tier 1: required

These catch bugs that would silently corrupt data or fail confusingly at load time. **All Tier 1 tests must pass.**

### `test_file_ingester.py`

- [x] `_validate_partition_args` returns `tuple | None` correctly. Parametrized:
  - `(None, None, None)` → `None`
  - `("partition_id", "86", "smallint")` → the 3-tuple
  - `("partition_id", None, None)` → `ValueError`
  - `(None, None, "smallint")` → `ValueError`
- [x] `_run_with_catalog_lifecycle` failure path (mocked conn): when the load action raises, tx1 'loading' UPDATE is committed, tx2 rolled back, tx3 'failed' UPDATE committed with `error_message` set, and the original exception re-raised. *Most subtle code in the package.*
- [ ] `_copy_from_s3` (boto3 mocked): gzipped body is decompressed when the key ends in `.gz` **or** `ContentEncoding == 'gzip'`; plain body is passed through; the leaf is TRUNCATEd before `copy_expert`.

### `test_delivery_loader.py`

- [x] `_load_source_config` accepts `replace_strategy: full` and `per_partition`; a missing `replace_strategy` still returns a dict (default behavior).
- [x] `_load_source_config` raises `ValueError` for `replace_strategy: bogus`.
- [x] `_load_source_config` raises `ValueError` naming the missing key when `column_list` is absent.
- [x] `load_pending_files` with no pending rows: `RuntimeError`; `ingestion_run` set to `'failed'`; `ingest_file` never called.
- [x] `load_pending_files` with `replace_strategy: full`: `_truncate_target_tables` called once before the per-file loop; with `per_partition` (or absent) not called.

### `test_finder.py`

- [x] `discover_delivery` raises `ValueError` for `delivery_date='2026-03-24'` (hyphens). Regression test for the `.format()` / regex-quantifier bug.
- [x] `_discover_files` (mocked S3 paginator): a required file group with zero matches raises `RuntimeError`; an optional one with zero matches is skipped.
- [x] `_write_catalog_rows`: with `pipeline_run_id=None` the `pipeline_run` INSERT happens; with a provided id the INSERT is skipped and that id is the FK target for `ingestion_run`.
- [x] `_insert_pdl_delivery` parses `pdl_dataset_id`. Parametrized:
  - keys include `MERGED_RECORDS_MONTHLY_V_34.0/...` → `'34.0'`
  - keys only from `data/` → `'unknown'`

### `test_integration.py` (also `integration`)

- [x] End-to-end happy path against local Postgres with the S3 fetch mocked to return a small fixture file: seed `pipeline_run` + `ingestion_run` + 3 `ingestion_file` rows, call `load_pending_files()`, assert all three reach `status='success'` with the fixture's row count and `ingestion_run` reaches `'success'` with matching totals.
- [x] `replace_strategy: full` wipes stale data between deliveries:
  1. Delivery A with partition values `{0, 1, 2}`; check `count(*) FROM raw.pdl_person`.
  2. Delivery B with `{0, 1}`; delivery A's partition 2 rows are gone.

### `processing/pdl_api/tests` (PDL mocked)

- [x] `call_pdl_with_retry`: 429 / 502 / 503 / 504 / network error retry up to the cap, honoring `Retry-After`; 200 / 404 / other 4xx return on first call; exhausted retries return the last result (audited as error). `sleep_fn` stubbed.
- [x] `PDLCaller` claim → audit → finalize: one audit row per claimed queue row; terminal status set via `map_status`.
- [x] Rate limiter paces calls; a spent credit cap (daily or monthly) stops the batch.
- [x] `BulkPDLCaller` / `process_enrichment_batch`: one HTTP call for up to 100 rows; per-record results reconciled by `metadata.input_list_id`; `limit > 100` raises `ValueError`; siblings with the same `pdl_company_id` marked `skipped_already_enriched`.
- [x] Company / location / school cleaners: `build_payload` and `map_status` mapping for matched, not-found, and error responses.
- [x] Integration (local Postgres, PDL mocked): queue rows drain end to end and audit rows land in the `pdl_api.*_call` tables.

### Tier 1 exit criteria

- `pytest -m tier1 -v` passes.
- `pytest -m "tier1 and not integration" -v` runs in a few seconds with no database, network, or credentials.
- `pytest -m "tier1 and integration"` passes against `make dev-up` Postgres.

---

## Tier 2: when code stabilizes

Add after Tier 1 lands and a few real PDL deliveries have gone through. Tag with `@pytest.mark.tier2`.

### `test_file_ingester.py`

- [ ] `_typed_literal` per type (smallint, integer, bigint, text, varchar; invalid type → `ValueError`)
- [x] `_run_with_catalog_lifecycle` happy path (load action returns N → tx1 + tx2 commit, returns N)
- [ ] `_run_with_catalog_lifecycle` when tx1 itself raises (broken connection)
- [ ] `ingest_file` helper integration: partitioned mode produces the 2-statement pre-COPY DDL; flat mode none; leaf name > 63 bytes raises `ValueError` before any DB call

### `test_delivery_loader.py`

- [ ] `_load_source_config` with all required keys and no partition keys → flat-mode dict
- [ ] `_load_source_config`: unknown source → `FileNotFoundError`
- [ ] `_load_source_config`: YAML is a list → `ValueError`
- [ ] `_load_source_config`: `partition_column` without `partition_value_type` → `ValueError`
- [ ] `_aggregate_from_files` corner cases (empty result, NULL `total_bytes`, `None` from cursor)
- [ ] `_load_one`: partitioned calls `ingest_file` with all 3 partition args; flat with all 3 `None`
- [ ] 3 pending files succeed sequentially: `ingest_file` called 3× in order
- [ ] 3 pending files succeed with `max_concurrency=3`: same final summary
- [x] 2nd file fails (sequential): loop stops after 2 calls; `ingestion_run` 'failed'
- [x] 2nd file fails (concurrent): `ingestion_run` 'failed'; exception re-raised
- [ ] `_truncate_target_tables` with several targets: N `TRUNCATE TABLE` statements with `sql.Identifier` quoting
- [x] Optional file group with no files still has its target truncated (`test_truncate_includes_config_file_groups_without_files`)

### `test_finder.py`

- [ ] `delivery_date='2026_3_24'` (single-digit month) → `ValueError`
- [ ] `_load_finder_config` validation: missing `sentinel`, missing / empty `file_groups`, wrong types → `ValueError`
- [ ] File group missing any of `name` / `s3_list_prefix` / `key_pattern` / `target_table` / `partition_value_from` → `ValueError` listing missing keys
- [ ] `_s3_object_exists`: 200 → True; 404 / NoSuchKey / NotFound → False; other `ClientError` re-raised
- [ ] Keys matching `s3_list_prefix` but not `key_pattern` are skipped
- [ ] Regex with `\d{5}` quantifier substitutes `{delivery_date}` via `str.replace` (regression for the `.format()` collision)
- [ ] `_insert_pdl_delivery`: `file_counts` jsonb has correct per-group counts
- [ ] `_insert_pdl_delivery`: re-run for the same `delivery_date` triggers `ON CONFLICT DO UPDATE`
- [ ] All catalog INSERTs in one transaction: a raise rolls everything back

### Ledger projection (`integration`)

- [ ] `raw.project_pdl_deltas()` on seeded delta rows: expected `pdl_id_aliases`, `pdl_inactive`, `merge_events` counts; re-run inserts nothing (idempotent).
- [ ] Reactivation: pdl_id already `deleted` in `pdl_inactive` reappears in `raw.pdl_person` → `reactivated` row (blocked: reactivation detection is not implemented).

### `test_integration.py`

- [ ] Concurrent vs sequential loads reach the same final state
- [ ] Re-running the loader when some files are already `'success'` reprocesses only `'pending'` rows
- [ ] Load raises on file 2 of 3 → file 1 success, file 2 failed, file 3 pending; `ingestion_run` failed
- [ ] Finder against `moto`-backed S3 (in-process or the local moto server): missing sentinel → `RuntimeError`, no catalog rows written
- [ ] Finder happy path with 5 fake files → 1 `pipeline_run` + 1 `ingestion_run` + 5 `ingestion_file` + 1 `pdl_delivery`

### `pdl_api`

- [ ] Stale `in_progress` claims are reclaimed
- [ ] Status transitions stay reversible (`enriched` / `skipped_already_enriched` → `pending`)

---

## Tier 3: full coverage

Tag with `@pytest.mark.tier3`. Probably not needed until several people work on the code.

- [ ] argparse boundaries (every flag's `required` / `default` / `choices`)
- [ ] Multi-page S3 list pagination (≥2 pages)
- [ ] Field-by-field type checks in `_load_finder_config` (e.g. `file_groups[].optional` must be bool)
- [ ] Integration: re-run `discover_delivery` for the same date updates `pdl_delivery` via ON CONFLICT
- [ ] Integration: Finder against a full real delivery layout in local S3 (usually covered by the smoke script)
- [ ] Concurrent `_truncate_target_tables` races
- [ ] File group `key_pattern` missing its named group → clean error
- [ ] Empty-string `partition_value` from the regex → clean error
- [ ] Loader `_finalize_run` UPDATE keeps existing values via COALESCE when NULLs are passed

---

## Out of scope

- Real (non-mocked) PDL API calls, except `pdl_smoke`.
- Real S3 buckets: exercised manually with the smoke script or `make ingest-pdl` against local S3.
- argparse argument-definition validation (tests the stdlib, not our code).
- Performance / load tests.

---

## How to run

```bash
conda activate pdl_test

# Tier 1 unit tests only (fast, no DB, no network)
pytest -m "tier1 and not integration" -v

# Full Tier 1, including integration tests against local Postgres
make dev-up
DATABASE_URL='postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl' \
  pytest -m tier1 -v

# Tier 1 + Tier 2
pytest -m "tier1 or tier2" -v

# Single file / single test
pytest processing/s3_ingester/tests/test_finder.py -v
pytest processing/s3_ingester/tests/test_finder.py::test_discover_delivery_rejects_hyphenated_date -v

# Live PDL smoke (spends credits; never in a default run)
PDL_API_KEY=... pytest -m pdl_smoke processing/pdl_api/tests/test_pdl_smoke.py

# dbt tests
make dbt-pdl
```

## Future expansion

When adding a component (e.g. cleansing-tier dbt models, a reactivation detector, a changelog-driven enrichment refresh), append a section here using the same Tier 1 / 2 / 3 layout and keep the per-component scope explicit.
