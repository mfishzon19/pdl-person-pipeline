# Data Pipeline Design Document

_Design rationale and technical specifications. Source of truth for **how** the pipeline is built. **What** and **why** live in [`../requirements/01_pipeline_requirements.md`](../requirements/01_pipeline_requirements.md)._

---

## Contents

1. [Scope and Pipeline Overview](#1-scope-and-pipeline-overview)
2. [Architecture Baseline: Stateless Content Rebuild + Stateful Identity Ledger](#2-architecture-baseline-stateless-content-rebuild--stateful-identity-ledger)
3. [Source Contract: PDL](#3-source-contract-pdl)
4. [Local Runtime and Separation of Concerns](#4-local-runtime-and-separation-of-concerns)
5. [Raw Layer Design](#5-raw-layer-design)
6. [S3 Ingester Framework (Finder → Loader → PDL projection)](#6-s3-ingester-framework-finder--loader--pdl-projection)
7. [PDL API: Company Enrichment and Cleaners](#7-pdl-api-company-enrichment-and-cleaners)
8. [dbt Layers: Staging → Ref → Integration → Cleansing](#8-dbt-layers-staging--ref--integration--cleansing)
9. [Identity Ledger](#9-identity-ledger)
10. [Catalog Logging](#10-catalog-logging)
11. [Data Modeling and Schema Migration Strategy](#11-data-modeling-and-schema-migration-strategy)
12. [Open Items](#12-open-items)

---

## 1. Scope and Pipeline Overview

The pipeline ingests **PDL (People Data Labs) Person** bulk deliveries, parses them into a normalized relational model, enriches and cleans company / location / school references through the **PDL API**, and applies cleansing routines on top. Everything runs **locally**: Postgres and Flyway in Docker Compose, an optional local S3 stand-in (moto server, `s3` service), and the Python ingester, PDL API callers and dbt run on the host in a conda env, driven by `make` targets.

PDL is the only source. The model keeps a `source` column where it matters so a second source could be added later without a schema redesign, but nothing in the current build reconciles multiple sources.

### The five-step flow

```
 S3 / local S3  (PDL Person delivery: data/ + delta_data/ + COMPLETED)
     │
     ▼
 1. INGEST  — processing/s3_ingester (Finder → Loader → PDL projection)
     │        raw.pdl_person, raw.pdl_{merged,deleted,opted_out}_records
     │        catalog.ingestion_run / ingestion_file / pdl_delivery
     │        catalog.pdl_id_aliases / pdl_inactive / merge_events  (identity ledger)
     ▼
 2. PARSE   — dbt staging (tag:pdl)
     │        staging.pdl_person_*_parsed  →  staging.pdl_person_*_unique
     ▼
 3. PDL API — processing/pdl_api
     │        company enrichment (bulk) + company / location / school cleaners
     │        pdl_api.*_input_list (queues) + pdl_api.*_call (audit)
     │        → dbt staging.pdl_api_company_parsed
     ▼
 4. MODEL   — dbt ref.* + integration.*
     │        canonical reference tables + person / company / school / experience / junctions
     ▼
 5. CLEANSE — cleansing routines (docs/pdl_data_cleansing/, design in 21_cleansing_layer_design.md)
```

| Step | Code | Reads | Writes | Make target |
|---|---|---|---|---|
| 1. Ingest | `processing/s3_ingester/run.py` | S3 / local S3 | `raw.*`, `catalog.*` | `make ingest-pdl` |
| 2. Parse | `processing/dbt/models/staging/pdl_person/` | `raw.pdl_person`, `catalog.pdl_id_aliases` | `staging.pdl_person_*` | `make dbt-pdl` (with step 4) |
| 3. PDL API | `processing/pdl_api/` + `processing/dbt/models/staging/pdl_api/` | `pdl_api.*_input_list`, PDL API | `pdl_api.*_call`, `staging.pdl_api_company_parsed` | `make clean-pdl`, `make enrich-pdl SOURCE_LIST=x MAX_CREDITS=n`, then `dbt build --select pdl_api_company_parsed+` |
| 4. Model | `processing/dbt/models/ref/`, `processing/dbt/models/integration/` | `staging.*` | `ref.*`, `integration.*` | `make dbt-pdl` (downstream of `tag:pdl`) |
| 5. Cleanse | `docs/pdl_data_cleansing/*.sql`, `scripts/` | `integration.*` | cleansing outputs | run by hand (see the cleansing README) |

`make pipeline-pdl` chains steps 1, 2 and 4 (`ingest-pdl` + `dbt-pdl`). Step 3 runs between them when new companies / locations / schools need API calls; its outputs are cached, so a rebuild without new API calls reuses the existing enrichment.

### What the integration layer delivers

- **Normalized Person data** at the integration layer: person, employment history (`integration.experience`), education (`integration.person_education`), location, skills / interests / languages.
- **Company and school entities** keyed by PDL ids, with company attributes from the person record overlaid by PDL Company enrichment where available.
- **Identity events** tracked across deliveries: PDL merges, deletions and opt-outs (see Section 9).
- **Stateless content rebuild + stateful identity ledger** (Section 2).

**Refresh cadence**: PDL delivers monthly. Each delivery is a full snapshot; the pipeline is re-run end to end per delivery.

---

## 2. Architecture Baseline: Stateless Content Rebuild + Stateful Identity Ledger

The target normalized model is defined in DBML (`modeling/dbml/integration.dbml`) and described in [`../data_model/`](../data_model/).

### Core architecture

The pipeline separates **content** from **identity metadata**:

- **Content** (`staging.*`, `ref.*`, `integration.*`): rebuilt fresh each run as a pure function of the latest raw snapshot. Attribute values are overwritten on every rebuild. No history retained.
- **Identity ledger** (`catalog.pdl_id_aliases`, `catalog.pdl_inactive`, `catalog.merge_events`, `catalog.person_key_map`): persists across runs. Accumulates identity events (merges, deactivations, id assignments). Never rebuilt from raw.
- **PDL API cache** (`pdl_api.*`): a related stateful exception. Queue and audit tables are preserved across runs so API calls are never repeated without reason (company enrichment is billed per record).

This is **not** pure stateless rebuild. It is **stateless content with a stateful identity spine**:

```
current integration content = f(latest PDL snapshot, current identity ledger state, PDL API cache)
```

Each run reads raw + ledger + API cache, rebuilds content, and updates the ledger as it goes.

### Why this split

The ledger exists because the requirements ask for:

- **Merge event tracking** over time (PDL's `MERGED_RECORDS` delta folder).
- **Deactivation tracking** (PDL deleted / opted-out events), with room to record a reactivation if the person returns.
- A path to a **stable internal person id** across runs (`catalog.person_key_map`), independent of PDL id churn.

A pure stateless rebuild would not distinguish "new person" from "merged person" for downstream consumers. Adding the ledger solves this with one stateful table family.

Content stays stateless-rebuildable because no attribute history is preserved — overwrites are fine. Recovery from content corruption is drop-and-rebuild. Recovery from ledger corruption is harder; see [Recovery paths](#recovery-paths).

### What this means concretely

- **Records overwrite on change.** Jane's title changing from "Senior Engineer" to "Principal Engineer" → next rebuild reflects "Principal Engineer". Prior value not preserved.
- **Nested sequences replace wholesale.** Work history and education come whole from the current PDL record.
- **Deactivation is ledger-only, not in integration content.** When PDL deletes or opts out a person, `catalog.pdl_inactive` appends a row with the reason. The integration tables hold the current view only. See [ADR-0007](../decisions/0007-integration-current-state-ledger-history.md).
- **Point-in-time queries** ("what did the data look like on April 1?") are not supported. Attribute history is out of scope.
- **Identity-event queries** ("which persons merged last month?") are supported via `catalog.merge_events` and `catalog.pdl_inactive`.

### The two stateful exceptions, contrasted

| | Identity ledger | PDL API cache |
|---|---|---|
| **Schema** | `catalog.pdl_id_aliases`, `catalog.pdl_inactive`, `catalog.merge_events`, `catalog.person_key_map` | `pdl_api.*_input_list`, `pdl_api.*_call` |
| **Purpose** | Preserve identity continuity and event history | Avoid re-paying for PDL API calls on each rebuild; keep an audit of every call |
| **Populated from** | Raw delta tables, via `raw.project_pdl_deltas()` | PDL API responses (`processing/pdl_api`) |
| **Loss recovery** | `pdl_id_aliases` / `pdl_inactive` / `merge_events`: reconstructable by replaying archived deliveries from S3. `person_key_map`: not reconstructable without new ids | Re-callable from the API, but billable |

### How the ledger interacts with the stateless rebuild

On every delivery:

1. **Ingester** loads `data/` (content) and `delta_data/` (identity events) from S3 into `raw.*`.
2. **Ledger projection** runs right after the load: `raw.project_pdl_deltas(delivery_date)` writes `pdl_id_aliases` + `merge_events` from `MERGED_RECORDS`, and `pdl_inactive` from `DELETED_RECORDS` / `OPTED_OUT_RECORDS`.
3. **Staging** rebuilds from `raw.pdl_person`, resolving pdl_ids through `pdl_id_aliases`.
4. **Ref + integration** rebuild from staging (and the PDL API cache).

Content tables are truncated and repopulated. Ledger tables are appended to in place.

### Future path if attribute history is ever needed

Attribute history is out of scope. If it is ever needed:

1. **Partitioned snapshots** of integration content, keyed by rebuild date. Additive; no data migration.
2. **SCD Type 2 on specific attributes** if snapshots are not enough.

Neither is ruled out by the current design; neither is built.

---

## 3. Source Contract: PDL

The source contract is the executable configuration the ingester reads (`processing/s3_ingester/configs/<source>.yaml`, Section 6) plus the reference that staging models depend on (field names, types, natural keys).

Contract fields: source name, schema, grain, volume, cadence, arrival pattern, S3 path convention and file naming, partition scheme, natural key, update semantics, known quality issues.

### PDL Person (bulk delivery)

**Delivery model.** PDL delivers a full monthly snapshot alongside delta folders that describe what changed since the previous delivery. The pipeline **consumes delta folders selectively**:

- `data/` — full snapshot of current persons. Drives content rebuild.
- `MERGED_RECORDS_MONTHLY_V_NN.N/` — consumed. Populates `catalog.pdl_id_aliases` and `catalog.merge_events` (`event_type = 'pdl_merge'`).
- `DELETED_RECORDS_MONTHLY_V_NN.N/` — consumed. Populates `catalog.pdl_inactive` with `reason = 'deleted'`.
- `OPTED_OUT_RECORDS_MONTHLY_V_NN.N/` — consumed when present. Populates `catalog.pdl_inactive` with `reason = 'opted_out'`. May be absent (OQ-3a in the requirements doc).
- `ADDED_RECORDS_MONTHLY_V_NN.N/` — **not consumed**. `data/` already contains these records.
- `UPDATED_RECORDS_MONTHLY_V_NN.N/` — **not consumed**. Same reasoning.

**Delta folder content.** JSON-in-CSV records carrying pdl_ids only (not full person records):

- ADDED / DELETED / UPDATED / OPTED_OUT: `{"id": "<pdl_id>"}` per row
- MERGED: `{"id": "<pdl_id>", "merged_to": "<pdl_id>"}` per row; `id` is the losing id, `merged_to` the winning one

**First delivery.** The first PDL delivery arrives with `data/` only (no `delta_data/`). The delta file groups are optional, so the Finder simply finds no delta files; the ledger fills from the second delivery onward.

**File format (`data/`).** Gzipped JSONL with a `.csv.gz` extension (PDL's naming). Loaded as single-column CSV via `DELIMITER E'\x01', QUOTE E'\x02'` so each line becomes one `jsonb` row. Files are partitions (`part-NNNNN.csv.gz`) of one dataset.

**Delivery completion.** PDL writes a `COMPLETED` sentinel (no extension) at the delivery root (`<delivery_date>/COMPLETED`). The Finder refuses to read a delivery whose sentinel is missing.

**Natural key.** `pdl_id`, extracted from the JSON payload in staging.

**Dataset identifier.** The PDL schema version appears in the delta folder names (`_V_NN.N`); the Finder records it on `catalog.pdl_delivery.pdl_dataset_id` (`'unknown'` on a first delivery with no deltas).

**Field-level freshness.** PDL provides `last_seen` / `first_seen`-style indicators on some fields; staging carries the ones the model uses (see [`15_pdl_staging_design.md`](15_pdl_staging_design.md)).

### PDL API (company enrichment + cleaners)

The second input is the PDL HTTP API, called by `processing/pdl_api` (Section 7):

| Endpoint | Purpose | Mode |
|---|---|---|
| `/v5/company/enrich/bulk` | Full company records keyed by `pdl_company_id` | Bulk, up to 100 records per call; billed per matched record |
| `/v5/company/clean` | Resolve a company name / website to a PDL company | One call per record |
| `/v5/location/clean` | Canonicalize a free-text location | One call per record |
| `/v5/school/clean` | Resolve a school name to a PDL school | One call per record |

Credentials: `PDL_API_KEY` from the environment / local `.env`. Tests never call the real API (all calls mocked).

### Source contract summary

| Source | Cadence | Content snapshot | Identity events consumed | Natural key | Raw format |
|---|---|---|---|---|---|
| PDL Person | monthly | `data/` (rebuilt each run) | MERGED, DELETED, OPTED_OUT (when present) under `delta_data/` | `pdl_id` | JSONL gzipped (`.csv.gz` extension) → `jsonb` |
| PDL API | on demand | `pdl_api.*_call` audit rows | — | `pdl_company_id` / queue id | JSON responses stored as `jsonb` |

---

## 4. Local Runtime and Separation of Concerns

### Stack

| Concern | Choice |
|---|---|
| Warehouse | Postgres (Docker Compose service `postgres`; db / user `pdl_etl`, password `pdl_etl_dev`, `localhost:5432`) |
| Schema migrations | Flyway, applied by the one-shot `flyway-init` compose service (Section 11) |
| Transformation | dbt Core, run on the host in the `pdl_test` conda env (`make dbt-pdl`) |
| Ingestion + API calls | Python, run on the host in the `pdl_test` conda env |
| Object storage | S3 for real PDL deliveries (standard AWS credential chain / `AWS_PROFILE`); local S3 stand-in (moto server; compose profile `ingester`, bucket `pdl-ingest-local`, in-memory) |
| Running steps | `make` targets (`ingest-pdl`, `dbt-pdl`, `pipeline-pdl`) |
| Secrets | Environment variables / local gitignored `.env` (`DATABASE_URL`, `PDL_API_KEY`, AWS credentials) |

Bring-up:

```bash
conda env create -f environment.yml   # once; creates the pdl_test env
make dev-up              # postgres + flyway-init + fixture-load (sanitized PDL fixture into raw)
make dev-up-ingester     # + local S3 seeded with a fixture delivery; raw.pdl_person left empty for the ingester
make pipeline-pdl        # ingest-pdl + dbt-pdl
make dev-down            # stop, keep volumes;  make dev-reset  to drop volumes
```

Containers are named `pdl_test_*`. The local stack design is in [`local-dev-design.md`](local-dev-design.md).

### Three non-overlapping layers of responsibility

**1. Runtime.** Docker Compose, the Makefile, `environment.yml`, the local helper scripts and fixtures in `infra/local/`. **No business or data logic lives here.** Answers "where does it run and how is it wired?"

**2. Data Modeling.** The ERD, the physical schema (tables, columns, constraints, indexes, partitions), and the Flyway migrations that realize it in Postgres. **Schema is authored in DBML** (`modeling/dbml/`) and projected into Flyway migrations and dbt scaffolding — see Section 11. This layer is the source of truth; the ingester, the PDL API caller and dbt respect it but don't own it.

**3. Data Processing.** The Python ingester (`processing/s3_ingester`), the PDL API caller (`processing/pdl_api`), shared helpers (`processing/common`) and the dbt project (`processing/dbt`). Answers "how does data move through the structures defined in layer 2?" Processing code never creates tables or alters schemas — it only reads and writes. (The ingester's lazy `CREATE TABLE ... PARTITION OF` for raw leaves is the one deliberate exception; leaves inherit the Flyway-owned parent's shape.)

A schema change is a migration in layer 2, not a coordinated rewrite across Python and SQL.

### S3 layout

```
# PDL Person — per-delivery prefix; data/ and delta_data/ underneath
s3://<pdl-bucket>/                            # local: s3://pdl-ingest-local/ on local S3
  <delivery_date>/                            # yyyy_mm_dd, e.g. 2026_04_22
    data/                                     # full snapshot
      part-NNNNN.csv.gz                       # hundreds of parts; each line = one JSON object
    delta_data/                               # absent on first delivery
      MERGED_RECORDS_MONTHLY_V_NN.N/          # {id, merged_to} per row — consumed
        part-NNNNN.csv.gz
      DELETED_RECORDS_MONTHLY_V_NN.N/         # pdl_ids only — consumed
        part-NNNNN.csv.gz
      OPTED_OUT_RECORDS_MONTHLY_V_NN.N/       # pdl_ids only; may be absent (OQ-3a) — consumed when present
        part-NNNNN.csv.gz
      ADDED_RECORDS_MONTHLY_V_NN.N/           # not consumed (already in data/)
      UPDATED_RECORDS_MONTHLY_V_NN.N/         # not consumed (already in data/)
    COMPLETED                                 # sentinel at delivery root
    field_stats.json                          # PDL metadata
```

Notes:
- The first delivery has `data/` only; `delta_data/` begins from the second delivery.
- Delta folder names carry a schema-version suffix (`_V_NN.N`). The ingester regex-matches it; the version doesn't change behavior because deltas contain only pdl_ids.
- The delivery bucket name is set in `configs/pdl_full.yaml`; `configs/pdl_full_local.yaml` is the byte-identical twin pointing at local S3.

---

## 5. Raw Layer Design

### Core principle: S3 is the archive, raw Postgres is the current snapshot

Raw tables hold **only the most recent delivery**. Historical raw data lives in S3, the immutable archive. If older raw data is ever needed (reprocessing, debugging, recovery), it is replayed from S3.

**PDL delta folders land in raw tables** too, one table per consumed delta type. This lets the same generic ingester handle every file uniformly. The ledger tables (`catalog.pdl_id_aliases`, `catalog.pdl_inactive`, `catalog.merge_events`) are populated from those raw delta tables by a separate post-load **projection function** (`raw.project_pdl_deltas`), not by the ingester.

Reasoning:

- S3 already guarantees immutability for raw deliveries; duplicating it in Postgres adds cost without safety.
- No attribute history is kept, so raw is a pass-through to staging.
- Bounded raw storage keeps partition management trivial.
- `loaded_at` on every row, plus `catalog.ingestion_file` (S3 key → partition), give traceability.

### Partitioning: 1:1 with source files

Each raw table is LIST-partitioned **1:1 with the files** that populate it:

| Table | Partition column | One leaf = | Approx leaves |
|---|---|---|---|
| `raw.pdl_person` | `partition_id smallint` (file index) | one `part-NNNNN.csv.gz` from `data/` | hundreds per delivery |
| `raw.pdl_merged_records` | `partition_id smallint` | one part file from `delta_data/MERGED_RECORDS_*/` | a few |
| `raw.pdl_deleted_records` | `partition_id smallint` | one part file from `delta_data/DELETED_RECORDS_*/` | a few |
| `raw.pdl_opted_out_records` | `partition_id smallint` | one part file from `delta_data/OPTED_OUT_RECORDS_*/` (when present) | zero or a few |

**Latest-only semantics**: each new file replaces its leaf's contents (TRUNCATE leaf, COPY into leaf). Old data never coexists with new in the same leaf.

**Lazy leaf creation**: the raw baseline migration creates only the **parent** partitioned tables. The Python ingester creates leaves on first use (`CREATE TABLE IF NOT EXISTS … PARTITION OF … FOR VALUES IN (…)` + `ALTER TABLE … ALTER COLUMN partition_id SET DEFAULT …`). Idempotent; no DDL churn after first appearance.

**Full-snapshot replace**: each PDL delivery is a complete snapshot, so the PDL config uses `replace_strategy: full` — the Loader TRUNCATEs every target table declared in the config's `file_groups` (all leaves) at delivery start, before the per-file loop. This prevents stale rows surviving in a leaf whose `partition_id` is present in delivery N but absent in N+1. Empty leaves stay behind for absent partition values; harmless. Optional groups with no files this delivery (e.g. no `DELETED_RECORDS`) are emptied too, so `raw.project_pdl_deltas()` never re-projects the previous delivery's delta rows under the new date.

### Atomic per-file replacement

Atomicity is per file, inside one psycopg2 transaction managed by the ingester:

```
BEGIN;
  CREATE TABLE IF NOT EXISTS raw.pdl_person_p_42 PARTITION OF raw.pdl_person FOR VALUES IN (42);
  ALTER TABLE raw.pdl_person_p_42 ALTER COLUMN partition_id SET DEFAULT 42;
COMMIT;
BEGIN;
  TRUNCATE raw.pdl_person_p_42;
  COPY raw.pdl_person_p_42 (payload) FROM STDIN WITH (FORMAT csv, DELIMITER E'\x01', QUOTE E'\x02');
      -- bytes fetched from S3 with boto3, gunzipped in Python, streamed over the connection
  SELECT count(*) FROM raw.pdl_person_p_42;
  UPDATE catalog.ingestion_file SET status='success', row_count=..., load_ended_at=now() WHERE ...;
COMMIT;
```

One file = one load transaction = one leaf updated, with the `catalog.ingestion_file` status change in the same transaction. A failure rolls back the leaf and records `status='failed'` in a separate transaction. Per-delivery success is decided from `catalog.ingestion_file` after the loop (Section 10).

### PDL ingestion: content + delta files all flow through raw

| S3 folder | Raw table | Purpose |
|---|---|---|
| `data/` | `raw.pdl_person` | Full snapshot content |
| `delta_data/MERGED_RECORDS_*/` | `raw.pdl_merged_records` | `{id, merged_to}` payloads |
| `delta_data/DELETED_RECORDS_*/` | `raw.pdl_deleted_records` | `{id}` payloads |
| `delta_data/OPTED_OUT_RECORDS_*/` (when present) | `raw.pdl_opted_out_records` | `{id}` payloads |
| `delta_data/ADDED_RECORDS_*/` | — | Skipped |
| `delta_data/UPDATED_RECORDS_*/` | — | Skipped |

After the load, `run.py` calls `raw.project_pdl_deltas(delivery_date)`, which reads `raw.pdl_*_records` and INSERTs into the ledger tables. Idempotent (`ON CONFLICT DO NOTHING` / `NOT EXISTS`). This keeps the ingester generic — it doesn't know what "MERGED_RECORDS" means; PDL-specific logic lives in the projection function.

On a first delivery the delta tables are empty and the projection inserts zero rows.

### No parsing at raw

Raw stores each JSON line unchanged as `jsonb` in a `payload` column. Parsing happens in staging (for `raw.pdl_person`) or in the projection function (for `raw.pdl_*_records`). Schema drift in PDL (a new or renamed JSON field) breaks staging, not raw: raw keeps ingesting and staging surfaces the issue as a test failure that can be fixed without reloading.

### Raw DDL

> Parent partitioned tables only; leaves are created on demand by the ingester. DBML source: `modeling/dbml/raw.dbml`; migration: `V2__raw_baseline.sql`.

```sql
-- PDL Person: JSON-in-CSV, full snapshot. One leaf per part file.
CREATE TABLE raw.pdl_person (
    partition_id  smallint    NOT NULL,
    payload       jsonb       NOT NULL,
    loaded_at     timestamptz NOT NULL DEFAULT now()
) PARTITION BY LIST (partition_id);

-- PDL Merged Records: {id, merged_to} per row.
-- Projected to catalog.pdl_id_aliases + catalog.merge_events.
CREATE TABLE raw.pdl_merged_records (
    partition_id  smallint    NOT NULL,
    payload       jsonb       NOT NULL,
    loaded_at     timestamptz NOT NULL DEFAULT now()
) PARTITION BY LIST (partition_id);

-- PDL Deleted Records: {id} per row. Projected to catalog.pdl_inactive (reason='deleted').
CREATE TABLE raw.pdl_deleted_records ( /* same shape */ ) PARTITION BY LIST (partition_id);

-- PDL Opted-Out Records: {id} per row; folder may be absent.
-- Projected to catalog.pdl_inactive (reason='opted_out').
CREATE TABLE raw.pdl_opted_out_records ( /* same shape */ ) PARTITION BY LIST (partition_id);
```

### Stateless rebuild means no delta-loss risk for content

Content is rebuilt from the latest raw snapshot on every run, so a delayed delivery or a failed run doesn't lose content semantics — the next successful run reconstructs everything from whatever raw holds. The ledger is the exception: delta folders for a skipped delivery must still be ingested (in order) for its merge / deletion events to be recorded.

---

## 6. S3 Ingester Framework (Finder → Loader → PDL projection)

### Design goal

A **single framework** that reads a per-source YAML config and handles every S3-delivered file group uniformly. Source-specific behavior lives in declarative config plus a small post-load hook; the runtime is shared.

### Modules

- **Finder (`processing/s3_ingester/finder.py`)** — per delivery, source-aware. Checks the sentinel, lists S3 per the `file_groups` in `configs/<source>.yaml` (regex-matched per key with a named partition-value group), then in **one transaction** INSERTs `catalog.pipeline_run` (unless a pre-minted id was passed), one `catalog.ingestion_run`, one `catalog.ingestion_file` row per file (`status='pending'`), and, for PDL, the `catalog.pdl_delivery` row (`status='received'`). Returns `ingestion_run_id`. The Finder does not load data and does not write to S3.
- **Loader (`processing/s3_ingester/delivery_loader.py`)** — per delivery, source-agnostic. Applies `replace_strategy`, reads the pending `ingestion_file` rows, loads them sequentially or through a thread pool (`--max-concurrency`), and finalizes `catalog.ingestion_run` with status and totals.
- **Ingester (`processing/s3_ingester/file_ingester.py`)** — per-file primitive. `ingest_file(...)` creates the partition leaf if needed, fetches the object with boto3 (honoring `AWS_ENDPOINT_URL`, so local S3 works unchanged), gunzips it, runs `TRUNCATE` + `COPY ... FROM STDIN`, counts rows, and manages the `ingestion_file` status lifecycle.
- **PDL projection (`processing/s3_ingester/pdl_projection_runner.py`)** — wraps `SELECT raw.project_pdl_deltas(:delivery_date)` and returns its jsonb summary.
- **Entry point (`processing/s3_ingester/run.py`)** — chains Finder → Loader → PDL projection → `pdl_delivery` finalize in one process. Each module also has its own CLI for re-running a single step.

### Data path: local COPY FROM STDIN

The only load path is a client-side COPY:

1. boto3 `get_object` on the S3 key.
2. Decompress in Python if the key ends in `.gz` or the object has `Content-Encoding: gzip`.
3. `TRUNCATE` the target leaf (encapsulated in the primitive, so a missed TRUNCATE can't silently turn a load into an append).
4. `COPY <leaf> (<column_list>) FROM STDIN WITH <copy_options>` on the same psycopg2 connection.
5. `SELECT count(*)` on the leaf → `row_count` (and `expected_row_count`; COPY FROM STDIN has no independent source-side count, so the two are always equal and the separate columns preserve the validation surface).

Trade-off: each object is held in memory before the COPY. PDL part files are tens of MB compressed, which is fine; stream if that changes.

**Partition-leaf creation lives in Python.** For flat (non-partitioned) targets the ingester skips leaf creation and loads the table directly; the per-file code path is otherwise the same.

**Concurrency** is inside one process: the Loader's thread pool loads several files in parallel, each on its own connection. Postgres CPU count is the natural ceiling.

### Running it

```bash
make dev-up-ingester     # local S3 + fixture delivery in s3://pdl-ingest-local/
make ingest-pdl          # python -m processing.s3_ingester.run --source pdl_full_local --delivery-date <yyyy_mm_dd> --max-concurrency 2
```

Against a real PDL bucket, from the `pdl_test` conda env:

```bash
export DATABASE_URL=postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl
export AWS_PROFILE=<profile with read access to the delivery bucket>
python -m processing.s3_ingester.run --source pdl_full --delivery-date 2026_04_22 --max-concurrency 4
```

CLI flags of `run.py`: `--source` (resolves `configs/<source>.yaml`), `--delivery-date` (`yyyy_mm_dd`), `--max-concurrency`, `--pipeline-version` (recorded on the run row).

### Finder responsibilities

1. Read `processing/s3_ingester/configs/<source>.yaml`.
2. Require the sentinel (`{delivery_date}/COMPLETED`); fail if absent.
3. For each `file_group`: list `s3_list_prefix`, keep keys matching `key_pattern`, extract `partition_value` from the named group. Required groups must match ≥1 file; optional groups may be empty.
4. In one transaction, write `ingestion_run` (plus its parent run row), N × `ingestion_file` (`pending`), and `pdl_delivery` (PDL only). Partial catalog state never persists.
5. Return `ingestion_run_id` to the caller.

### Loader / Ingester responsibilities

1. Query the delivery's pending files: `SELECT … FROM catalog.ingestion_file WHERE ingestion_run_id = ? AND status = 'pending'`.
2. If `replace_strategy: full`, TRUNCATE every target table in the config's `file_groups` first (including optional groups with no files this delivery).
3. Load each file with `ingest_file(...)`: `status='loading'` + `load_started_at`, then TRUNCATE + COPY + count, then `status='success'`, `row_count`, `expected_row_count`, `load_ended_at` — committed with the data.
4. **Fail fast**: on the first per-file failure the load transaction rolls back, the row is marked `status='failed'` with `error_message`, and the Loader aborts the rest of the delivery.
5. Finalize `catalog.ingestion_run` (`status`, `ended_at`, `total_file_count`, `total_row_count`, `total_bytes`).

### Source-specific post-load work (PDL)

After the Loader succeeds, `run.py`:

1. Calls `raw.project_pdl_deltas(delivery_date)` (`R__function_project_pdl_deltas.sql`). Reads `raw.pdl_*_records`; INSERTs into `catalog.pdl_id_aliases`, `catalog.pdl_inactive`, `catalog.merge_events`. All rows from one delivery share `observed_at = delivery_date::timestamptz`, which makes re-runs hit predictable conflicts. Returns counts per destination.
2. Finalizes `catalog.pdl_delivery`: `status='success'`, `completed_at`, `row_counts` (per raw target table), `pdl_merge_event_count`, `pdl_deleted_count`, `pdl_opted_out_count`. On failure it sets `status='failed'` and `error_message`.

Post-load is selected by `source.startswith("pdl_")`; if another source ever needs a hook, this becomes a YAML-declared `post_load:` key.

**Reactivation** (a pdl_id that was deleted / opted out reappears in `data/`) is not detected. A detector would be a second function that compares `raw.pdl_person` ids with the latest `pdl_inactive` event and appends `reason='reactivated'`.

### Config per source (YAML)

Source configs live in `processing/s3_ingester/configs/` and are read by both Finder and Loader. Per-file values (`s3_key`, `target_table`, `partition_value`) come from the `catalog.ingestion_file` rows the Finder writes, not from the YAML.

```yaml
# pdl_full.yaml  (pdl_full_local.yaml is identical except bucket: pdl-ingest-local)

# Loader-facing keys
column_list: payload
copy_options: "(FORMAT csv, DELIMITER E'\x01', QUOTE E'\x02')"
bucket: <your-pdl-delivery-bucket>
region: us-east-1
partition_column: partition_id
partition_value_type: smallint
replace_strategy: full          # full snapshot: TRUNCATE parents at delivery start

# Finder-facing keys
sentinel:
  key_pattern: "{delivery_date}/COMPLETED"

file_groups:
  - name: pdl_data
    s3_list_prefix: "{delivery_date}/data/"
    key_pattern: "^{delivery_date}/data/part-(?P<partition_id>\\d{5})\\.csv\\.gz$"
    target_table: raw.pdl_person
    partition_value_from: partition_id
    optional: false

  - name: pdl_merged
    s3_list_prefix: "{delivery_date}/delta_data/"
    key_pattern: "^{delivery_date}/delta_data/MERGED_RECORDS_MONTHLY_V_[^/]+/part-(?P<partition_id>\\d{5})\\.csv\\.gz$"
    target_table: raw.pdl_merged_records
    partition_value_from: partition_id
    optional: true              # absent on first delivery

  - name: pdl_deleted           # → raw.pdl_deleted_records, same shape, optional
  - name: pdl_opted_out         # → raw.pdl_opted_out_records, same shape, optional (OQ-3a)
```

A new S3-delivered file group is a YAML edit plus a test, not new ingester code.

### Catalog touch-points

- **Finder**: `ingestion_run` (INSERT, `started`), `ingestion_file` (INSERT, `pending`), `pdl_delivery` (UPSERT, `received`).
- **Ingester / Loader**: `ingestion_file` per-file UPDATEs; `ingestion_run` terminal UPDATE.
- **Post-load**: ledger tables via `raw.project_pdl_deltas`; `pdl_delivery` terminal UPDATE.

Full table specs in Sections 9 and 10.

---

## 7. PDL API: Company Enrichment and Cleaners

The generic PDL API caller (`processing/pdl_api`) is specified in [`18_pdl_api_generic_caller.md`](18_pdl_api_generic_caller.md). This section covers where it sits in the pipeline.

### Principle

Company enrichment is the most expensive component by API cost and the most stable by nature. **Cache aggressively, invalidate deliberately.** Every call is logged in an append-only audit table, and the queue tables record what has already been resolved so reruns skip it.

### Shape: queue → caller → audit → dbt

```
pdl_api.<domain>_input_list   (queue; status per row)
   │   rows claimed by worker_id, rate-limited, credit-capped
   ▼
PDL API  (/v5/company/enrich/bulk, /v5/company/clean, /v5/location/clean, /v5/school/clean)
   ▼
pdl_api.<domain>_call          (append-only audit: request_json, response_status, response_json, called_at)
   ▼
dbt: staging.pdl_api_company_parsed → integration.company / company_affiliation
```

| Domain | Caller | Queue | Audit |
|---|---|---|---|
| Company enrichment | `CompanyEnrichmentCaller` (`BulkPDLCaller`) | `pdl_api.company_input_list` (`enrichment_status`) | `pdl_api.company_enrichment_call` |
| Company cleaner | `CompanyCleanerCaller` (`PDLCaller`) | `pdl_api.company_input_list` (`cleaner_status`) | `pdl_api.company_cleaner_call` |
| Location cleaner | `LocationCleanerCaller` (`PDLCaller`) | `pdl_api.location_input_list` | `pdl_api.location_cleaner_call` |
| School cleaner | `SchoolCleanerCaller` (`PDLCaller`) | `pdl_api.school_input_list` | `pdl_api.school_cleaner_call` |

Queue rows are inserted with `INSERT … ON CONFLICT DO NOTHING` on the natural key, so the same company / location / school string arriving twice yields one queue row. Company queue rows can be pre-resolved (`pdl_search_params = {"id": "<pdl_company_id>"}`, cleaner not needed) — the common case, since every PDL person experience already carries a `company_pdl_id`.

Running a drain (from the `pdl_test` env with `DATABASE_URL` and `PDL_API_KEY` set):

```bash
python -m processing.pdl_api.company_cleaner  drain [--rpm N]
python -m processing.pdl_api.location_cleaner drain [--rpm N]
python -m processing.pdl_api.school_cleaner   drain [--rpm N]
```

Company enrichment is billed, so it always runs against one source list with an explicit credit cap:

```bash
python -m processing.pdl_api.company_enrichment run --source-list <list> --max-credits N [--rpm N]
```

`make clean-pdl` runs the three cleaner drains; `make enrich-pdl SOURCE_LIST=x MAX_CREDITS=n` runs enrichment. Both refuse to start without `PDL_API_KEY`. See [`processing/pdl_api/README.md`](../../processing/pdl_api/README.md).

Each `drain` first reclaims stale `in_progress` rows, then loops `process_batch` until the queue has no pending rows or a credit cap (daily or monthly) is hit.

### What dbt consumes

- `staging.pdl_api_company_parsed` parses `pdl_api.company_enrichment_call.response_json`, one row per `pdl_company_id`. `integration.company`, `integration.company_affiliation` and some `ref.*` tables (industry, `pdl_relationship`) read it directly. `staging.pdl_api_company_unique` exists in the DBML but has no dbt model; it becomes the dedup step only if re-enrichment is built (doc 18).
- Location and school cleaner audits are declared as dbt sources; no staging model consumes them. They are inputs for the cleansing layer (Section 8).

### Company lifecycle columns (schema design — implementation deferred)

The enrichment cache should eventually support invalidation when a company materially changes (merged, moved, renamed, dissolved). Columns to model when that work starts:

| Column | Purpose |
|---|---|
| `pdl_company_id` | Natural key |
| `enriched_at` | Last successful enrichment |
| `enrichment_version` | Version of enrichment logic / API contract |
| `source_watermark` | Last-known PDL "updated" marker; detects upstream drift |
| `status` | `active`, `merged`, `moved`, `renamed`, `dissolved` |
| `merged_into_pdl_company_id` / `succeeded_by_pdl_company_id` | Successor links |
| `is_current`, `superseded_at`, `superseded_reason` | Supersession tracking |

Refresh via PDL's company changelog is discussed in doc 18.

*Person enrichment is out of scope.* The PDL Person bulk delivery already provides the person attributes the model needs.

---

## 8. dbt Layers: Staging → Ref → Integration → Cleansing

Layer mechanics and naming conventions are in [`16_dbt_pipeline_layers.md`](16_dbt_pipeline_layers.md); PDL staging specifics in [`15_pdl_staging_design.md`](15_pdl_staging_design.md); the cleansing layer in [`21_cleansing_layer_design.md`](21_cleansing_layer_design.md).

### Layer structure

```
raw  →  staging  →  ref  →  integration  →  (cleansing outputs)
                ↑
       pdl_api (API cache) → staging.pdl_api_company_*
```

| Layer | Schema | Reads from | What lives here |
|---|---|---|---|
| raw | `raw` | S3 via the ingester | Untouched `jsonb` payloads |
| staging | `staging` | `raw.*`, `catalog.pdl_id_aliases`, `pdl_api.*` | Parse, type, deduplicate, alias-resolve. One source per model. No business rules. |
| ref | `ref` | staging | Canonical reference tables (country / state / city / metro / location, industry, job title class / role / subrole, seniority, skill, interest, language, PDL relationship). Loader-discovered values; see [ADR-0005](../decisions/0005-ref-population-layer.md), [ADR-0011](../decisions/0011-loader-discovered-ref-tables.md). |
| integration | `integration` | staging + ref | The normalized model: `person`, `company`, `company_affiliation`, `school`, `experience`, `person_education`, and junctions (`person_country`, `person_state_province`, `person_location`, `person_skill`, `person_interest`, `person_language`, `experience_location`, `experience_industry`, `experience_seniority_level`). Entity docs in [`../data_model/`](../data_model/). |
| cleansing | (see doc 21) | integration / staging | Normalization, dedup, hierarchy and quality rules. |

### Staging naming

Single `staging` schema with source prefixes, following `parsed → unique`:

- `staging.pdl_person_parsed` + per-sub-object `_parsed` tables (`experience`, `education`, `companies`, `schools`, `addresses`): JSON → typed columns via `JSON_TABLE`. One row per raw record / array element; no ledger reads.
- `staging.pdl_person_unique` + matching `_unique` tables: within-delivery dedup and alias resolution. `pdl_person_unique` walks `catalog.pdl_id_aliases` (old → current pdl_id) and keeps one row per current pdl_id.
- `staging.pdl_api_company_parsed`: PDL Company enrichment responses (no `_unique` model; see Section 7).

Staging does not apply inactive flags from `catalog.pdl_inactive`; deleted / opted-out persons are simply absent from the next full snapshot.

### Integration

The integration models build the current-state entities from staging + ref. Surrogate `id`s are computed in dbt (`ROW_NUMBER() OVER (ORDER BY <natural key>)`, [ADR-0008](../decisions/0008-dbt-computed-ref-surrogate-ids.md), [ADR-0010](../decisions/0010-extend-dbt-computed-surrogate-ids-to-integration.md)) and are **not stable across rebuilds**; PDL ids (`pdl_id`, `pdl_company_id`, school `pdl_id`) are the stable keys. `catalog.person_key_map` (Section 9) is the reserved place for a stable internal person id; it is not populated and `integration.person` does not join to it.

Company attributes: the person record's company fields are the base; PDL Company enrichment (`staging.pdl_api_company_parsed`) overlays them when the company has been enriched.

### Cleansing

Cleansing routines (name / title / company-name / location / LinkedIn-URL normalization, education and experience dedup, degree families, company hierarchy, broken-company detection, school roll-ups) are prototyped as SQL in [`../pdl_data_cleansing/`](../pdl_data_cleansing/) against `integration.*`. The pipeline target is a dbt `_cleaned` tier upstream of `integration.*`, per doc 21.

### CDC

- **Between deliveries** (source change): identity events (merges, deletions, opt-outs) come from the delta folders into the ledger. Attribute-level change is not tracked (no attribute history).
- **Between runs** (integration change): not tracked; integration is rebuilt each run. Identity events are queryable via `catalog.merge_events` and `catalog.pdl_inactive`.

### Materialization and tags

All staging / ref / integration models use `materialized='incremental'` + `incremental_strategy='append'` + `pre_hook='TRUNCATE TABLE {{ this }} RESTART IDENTITY CASCADE'` + `on_schema_change='fail'` against Flyway-owned tables (Section 11). Staging is persisted (not views), so rebuilding a downstream subset reads frozen staging output.

PDL person staging is tagged `pdl` in `dbt_project.yml`. `make dbt-pdl` runs `dbt build --select tag:pdl+`, which builds PDL staging and everything downstream (ref + integration).

FK constraints across `ref` and `integration` are dropped at `on-run-start` and recreated `NOT VALID` at `on-run-end` ([ADR-0009](../decisions/0009-fk-constraint-drop-recreate-for-rebuild.md)); dbt `relationships` tests are the integrity check. Large tables drop secondary indexes before the INSERT and rebuild them after ([ADR-0003](../decisions/0003-staging-bulk-load-pattern-1.md)).

---

## 9. Identity Ledger

The `catalog` schema holds two kinds of table that share a schema for ownership clarity (Flyway-owned, not dbt-owned):

1. **Identity ledger** — stateful tables that preserve identity continuity across runs (this section).
2. **Run logging** — delivery state, run and file history (Section 10).

The ledger tables persist across runs and are never rebuilt from raw. DBML source: `modeling/dbml/catalog.dbml`.

### `catalog.pdl_id_aliases`

**Stores:** PDL merge mappings, old pdl_id → current pdl_id. Append-only.

```sql
CREATE TABLE catalog.pdl_id_aliases (
    old_pdl_id          text        NOT NULL PRIMARY KEY,
    current_pdl_id      text        NOT NULL,
    observed_at         timestamptz NOT NULL,
    delivery_date       date        NOT NULL              -- which delivery surfaced this
);
CREATE INDEX idx_pdl_id_aliases_current ON catalog.pdl_id_aliases (current_pdl_id);
```

**Populated by:** `raw.project_pdl_deltas(delivery_date)` from `raw.pdl_merged_records`; `ON CONFLICT (old_pdl_id) DO NOTHING`.

**Read by:** `staging.pdl_person_unique` (alias resolution). Chains (A→B last month, B→C this month) are walked so A lands on C.

### `catalog.pdl_inactive`

**Stores:** Append-only log of PDL deactivation events. The `reason` check constraint also allows `'reactivated'`, but nothing writes it.

```sql
CREATE TABLE catalog.pdl_inactive (
    pdl_id              text        NOT NULL,
    reason              text        NOT NULL,             -- 'deleted' | 'opted_out' | 'reactivated'
    observed_at         timestamptz NOT NULL,
    delivery_date       date        NOT NULL,
    PRIMARY KEY (pdl_id, observed_at)
);
CREATE INDEX idx_pdl_inactive_pdl_id ON catalog.pdl_inactive (pdl_id);
```

**Populated by:** `raw.project_pdl_deltas` from `raw.pdl_deleted_records` (`'deleted'`) and `raw.pdl_opted_out_records` (`'opted_out'`); `ON CONFLICT (pdl_id, observed_at) DO NOTHING`. `'reactivated'` is reserved for a reactivation detector that is not implemented (Section 12).

**Current state** of a pdl_id = its latest event (`ROW_NUMBER() OVER (PARTITION BY pdl_id ORDER BY observed_at DESC)`).

### `catalog.merge_events`

**Stores:** Append-only audit of merges.

```sql
CREATE TABLE catalog.merge_events (
    event_id            bigserial   PRIMARY KEY,
    event_type          text        NOT NULL,             -- 'pdl_merge' | 'identity_resolution_merge' | 'manual_merge'
    losing_id           text        NOT NULL,             -- pdl_id for pdl_merge; internal_person_id (as text) otherwise
    winning_id          text        NOT NULL,
    observed_at         timestamptz NOT NULL,
    notes               text                              -- populated for manual_merge
);
```

**Populated by:** `raw.project_pdl_deltas` (`'pdl_merge'`, deduped with `NOT EXISTS` on `(event_type, losing_id, winning_id, observed_at)`). `'identity_resolution_merge'` and `'manual_merge'` are reserved.

### `catalog.person_key_map`

**Stores:** a stable `internal_person_id` per identity signature. Reserved: the catalog baseline creates it, but nothing populates it.

```sql
CREATE TABLE catalog.person_key_map (
    internal_person_id  bigserial   PRIMARY KEY,
    identity_signature  text        NOT NULL UNIQUE,      -- e.g. normalized LinkedIn URL, else a hash of name + company + location + school
    status              text        NOT NULL,             -- 'active' | 'inactive' | 'merged_into'
    merged_into_id      bigint      REFERENCES catalog.person_key_map(internal_person_id),
    first_seen_at       timestamptz NOT NULL,
    last_seen_at        timestamptz NOT NULL
);
```

When wired, the integration build would look up / insert by signature (`INSERT … ON CONFLICT (identity_signature) DO UPDATE`), flip status on deactivation / reactivation, and append `merge_events` when two signatures unify. It is the one ledger table that **cannot be reconstructed from the S3 archive**.

### Recovery paths

**Content corruption** (a raw load failed mid-flight, staging output is wrong): re-run the affected step(s). Stateless rebuild guarantees correctness as long as raw is intact; raw itself can be reloaded from S3.

**Ledger corruption**: `pdl_id_aliases`, `pdl_inactive` and `merge_events` can be rebuilt by replaying archived deliveries' delta folders in delivery order. `person_key_map`, once populated, cannot. Mitigation: dump the `catalog` schema (`pg_dump -n catalog`) before risky migrations; keep ledger writes inside transactions.

### Concurrency

Runs are started by hand, one delivery at a time. Two concurrent runs against the same delivery don't corrupt content (each file is TRUNCATE + COPY; the ledger projection is idempotent) but produce confusing catalog rows. Avoid it; `catalog.pdl_delivery.status = 'processing' | 'received'` shows a run in flight.

---

## 10. Catalog Logging

What the pipeline records about its own runs, so "did this delivery load completely, and what did it change?" is answerable in SQL. The catalog stores ETL semantics (what was loaded, how many rows, which files, which identity events); process logs (stdout of the `make` targets / containers) hold stack traces and debug output.

### What is logged, per run and per file

| Table | Grain | Written by | Lifecycle |
|---|---|---|---|
| `catalog.ingestion_run` | one per (source, delivery) load | Finder INSERT (`started`); Loader UPDATE | `success` / `failed` + `ended_at`, `total_file_count`, `total_row_count`, `total_bytes`, `error_message` |
| `catalog.ingestion_file` | one per S3 file | Finder INSERT (`pending`); `file_ingester` UPDATEs | `loading` → `success` / `failed`; `expected_row_count`, `row_count`, `size_bytes`, `load_started_at`, `load_ended_at`, `error_message` |
| `catalog.pdl_delivery` | one per PDL delivery date | Finder UPSERT (`received`); `run.py` UPDATE | `success` / `failed`; `file_counts`, `row_counts`, `pdl_merge_event_count`, `pdl_deleted_count`, `pdl_opted_out_count`, `completed_at`, `error_message` |
| Ledger tables (Section 9) | one per identity event | `raw.project_pdl_deltas` | append-only |
| `pdl_api.*_call` | one per PDL API call (per record for bulk) | `processing/pdl_api` | append-only; `bulk_batch_id` groups a bulk call |
| `catalog._dropped_fks` | one per FK dropped around a dbt run | dbt `on-run-start` / `on-run-end` hooks | rows exist only while a dbt run is in flight or after an aborted one |

### Idempotency

Re-running a delivery is safe at the content and ledger level:

- **Finder**: `pdl_delivery` is UPSERTed on `delivery_date`; a re-run creates a new `ingestion_run` with fresh `ingestion_file` rows, so history of attempts is kept. `ingestion_file` is unique on `(ingestion_run_id, s3_key)`.
- **Loader / Ingester**: `replace_strategy: full` plus per-file TRUNCATE + COPY make a reload produce the same raw content. If a run fails partway, re-running `run.py` starts a new `ingestion_run` and reloads the whole delivery; the Loader CLI run against the original `ingestion_run_id` loads only the files still `pending`.
- **Projection**: `ON CONFLICT DO NOTHING` / `NOT EXISTS` with `observed_at = delivery_date` — the same delivery projects zero new rows the second time.
- **pdl_delivery finalize**: keyed on `delivery_date`, so the latest attempt's status wins.
- **PDL API**: queue rows move to terminal statuses and are not re-claimed; stale `in_progress` rows are reclaimed by `drain()` on the next start.

### Validating a delivery

```sql
-- Did every file load, and do source/destination counts agree?
SELECT
    COUNT(*) FILTER (WHERE status = 'success')              AS loaded_ok,
    COUNT(*) FILTER (WHERE status = 'failed')               AS failed,
    COUNT(*) FILTER (WHERE status IN ('pending','loading')) AS not_done,
    COUNT(*) FILTER (WHERE row_count <> expected_row_count) AS mismatched
FROM catalog.ingestion_file
WHERE ingestion_run_id = :ingestion_run_id;

-- Delivery summary
SELECT delivery_date, pdl_dataset_id, status, file_counts, row_counts,
       pdl_merge_event_count, pdl_deleted_count, pdl_opted_out_count,
       started_at, completed_at, error_message
FROM catalog.pdl_delivery
ORDER BY delivery_date DESC;

-- Load attempts for a delivery
SELECT ingestion_run_id, started_at, status, total_file_count, total_row_count, error_message
FROM catalog.ingestion_run
WHERE delivery_date = :delivery_date
ORDER BY started_at DESC;
```

### Table specs (run logging)

#### `catalog.ingestion_run`

```sql
CREATE TABLE catalog.ingestion_run (
    ingestion_run_id      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    pipeline_run_id       uuid        NOT NULL,             -- FK to a parent run row the Finder inserts; not otherwise used
    source_name           text        NOT NULL,             -- config name, e.g. 'pdl_full'
    delivery_date         date        NOT NULL,
    sub_key               jsonb,                            -- per-source sub-id; NULL for PDL
    status                text        NOT NULL,             -- 'started' | 'success' | 'failed'
    started_at            timestamptz NOT NULL,
    ended_at              timestamptz,
    duration_seconds      numeric,
    total_file_count      int,
    total_row_count       bigint,
    total_bytes           bigint,
    error_message         text
);
```

#### `catalog.ingestion_file`

```sql
CREATE TABLE catalog.ingestion_file (
    ingestion_file_id     uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    ingestion_run_id      uuid        NOT NULL REFERENCES catalog.ingestion_run(ingestion_run_id),
    s3_key                text        NOT NULL,
    target_table          text        NOT NULL,             -- e.g. 'raw.pdl_person'
    partition_value       text        NOT NULL,             -- cast to the partition column type for leaf DDL
    expected_row_count    bigint,                           -- source-side count
    row_count             bigint,                           -- COUNT(*) on the leaf after load
    size_bytes            bigint,
    status                text        NOT NULL,             -- 'pending' | 'loading' | 'success' | 'failed'
    load_started_at       timestamptz,
    load_ended_at         timestamptz,
    error_message         text,
    UNIQUE (ingestion_run_id, s3_key)
);
```

#### `catalog.pdl_delivery`

```sql
CREATE TABLE catalog.pdl_delivery (
    delivery_date             date        PRIMARY KEY,
    pdl_dataset_id            text        NOT NULL,          -- from MONTHLY_V_NN.N in delta keys; 'unknown' if none
    complete_md_seen_at       timestamptz NOT NULL,          -- when the Finder saw the COMPLETED sentinel
    file_counts               jsonb,                         -- per file_group, e.g. {"pdl_data": 500, "pdl_merged": 1, ...}
    row_counts                jsonb,                         -- per raw target table, populated post-load
    status                    text        NOT NULL,          -- 'received' | 'processing' | 'success' | 'failed'
    started_at                timestamptz,
    completed_at              timestamptz,
    error_message             text,
    pdl_merge_event_count     int,
    pdl_deleted_count         int,
    pdl_opted_out_count       int,
    created_at                timestamptz NOT NULL DEFAULT now(),
    updated_at                timestamptz NOT NULL DEFAULT now()
);
```

---

## 11. Data Modeling and Schema Migration Strategy

### Schema authoring and generation workflow

The schema is **authored in DBML** and projected into Flyway migrations and dbt scaffolding.

```
    DBML (authored)
         |
         v
  Scaffolding script (Python, modeling/scaffolding — planned)
         |
         +--> Flyway migration SQL  (applied to Postgres; creates tables)
         +--> dbt model stubs        (SQL skeletons to fill with logic)
         +--> dbt schema.yml         (column definitions, descriptions)
         +--> ERD / docs             (via dbdiagram.io or equivalent)
```

**Authoring**: DBML files (`modeling/dbml/<schema>.dbml`) are the single source of truth for tables, columns, types, constraints, relationships, indexes and comments. See [ADR-0001](../decisions/0001-dbml-owns-table-shape-across-layers.md).

**Generation**: the scaffolding compiler is not built yet; until it is, migrations are hand-authored against the DBML (marked "transitional" below).

**Population**: dbt populates the Flyway-created tables. Engineers write the SELECT logic and tests; they don't re-declare columns or types.

### Why this flow

- **Single source of truth.** DBML is authoritative; Flyway SQL, dbt YAML and docs are projections.
- **No drift.** `on_schema_change='fail'` makes dbt fail if its SELECT disagrees with the Flyway-created table.
- **Living ERD.** DBML renders to diagrams with standard tooling.
- **Clear review surface.** DBML diffs show schema changes plainly.

### Division of responsibility

| Artifact | Authored by | Generated from | Consumed by |
|---|---|---|---|
| DBML files | Engineer | — | Scaffolding / migration author |
| Flyway migration SQL | Scaffolding (hand-authored today) | DBML | Flyway |
| dbt model stubs | Scaffolding | DBML | Engineer |
| dbt schema.yml | Scaffolding (+ engineer for tests) | DBML | dbt |
| dbt model logic (SELECT) | Engineer | — | dbt |
| ERD and docs | Scaffolding | DBML | Humans |

**Flyway defines the schema. dbt populates it.**

**dbt may own:** transformation logic; materialization within the Flyway-defined shape; `post_hook` indexes for bulk-load performance; tests.

**dbt may not own:** table existence, column presence / types / order / nullability, primary / foreign / check constraints, partitioning, anything that must survive `dbt run --full-refresh`.

### Migration tool: Flyway

Plain-SQL, forward-only migrations with a simple mental model; the schema lifecycle here is mostly additive. Liquibase would only be worth revisiting if rollback became a hard requirement.

### Requirements

- **Recreate from scratch**: the full `V1..V_n` sequence applied to an empty database produces exactly the state DBML describes. `make dev-reset && make dev-up` exercises this every time (the `flyway-init` service migrates a fresh Postgres).
- **Versioned forward-only migrations** for all schema changes.
- **Migrations run before any pipeline step**: `flyway-init` runs on `make dev-up` before `fixture-load`, so the schema exists before anything is ingested or built.

### Division of ownership between Flyway and dbt

| Object | DDL owner | Data flow owner |
|---|---|---|
| `raw.*` parents (leaves lazily by the ingester) | Flyway (`raw.dbml`) | Python ingester (S3 → raw via COPY FROM STDIN) |
| `catalog.*` run-logging tables | Flyway (`catalog.dbml`) | Python ingester; dbt hooks (`_dropped_fks`) |
| `catalog.*` identity ledger | Flyway (`catalog.dbml`) | `raw.project_pdl_deltas` |
| `ref.*` | Flyway (`ref.dbml`) | dbt |
| `pdl_api.*` queues + audits + driver views | Flyway (`pdl_api.dbml`) | Python API caller |
| `staging.*` | Flyway (`staging.dbml`) | dbt (incremental + TRUNCATE pre_hook + append) |
| `integration.*` | Flyway (`integration.dbml`) | dbt (incremental + TRUNCATE pre_hook + append; **not** `'table'`) |
| Postgres functions | Flyway (`R__function_*.sql`) | — |
| Permissions / roles | Flyway (`R__permissions.sql`, `R__roles.sql`) | — |
| Views | Flyway (`R__view_*.sql`, hand-authored) | — |
| Indexes | Flyway (DBML, or hand-authored sidecars for expression / partial / trigram) | dbt `post_hook` for drop-and-rebuild around bulk loads |

Materialization rules for DBML-managed schemas (`staging`, `integration`, `ref`):
- **Default**: `materialized='incremental'` + `incremental_strategy='append'` + `pre_hook='TRUNCATE TABLE {{ this }} RESTART IDENTITY CASCADE'` + `on_schema_change='fail'`.
- `materialized='view'` allowed for rare derived models.
- **`materialized='table'` is forbidden** — it drops and recreates, bypassing Flyway's contract.

The identity ledger tables are Flyway-owned for both DDL and persistence because they encode state that must survive any rebuild. Other Flyway-owned tables are rebuildable from source; they're Flyway-owned for DDL clarity.

### Hand-authored vs DBML-generated migrations

Every migration file carries a provenance banner:

- `-- GENERATED FROM DBML.` — produced by the scaffolding compiler (once it ships) from the named DBML file. Not hand-edited.
- `-- HAND-AUTHORED.` — everything DBML cannot express, plus transitional files written by hand against DBML until the compiler exists.

**Filename convention**: `V<n>__<schema>_<purpose>.sql` for versioned; `R__<purpose>.sql` for repeatable. Schema name first after `__`.

Migration inventory (baselines and categories; see `modeling/flyway/migrations/` for the full list — gaps in the version sequence are expected):

| File | Provenance | Why |
|---|---|---|
| `V1__catalog_baseline.sql` | Hand-authored (transitional) | Catalog baseline (ledger + run logging) |
| `V2__raw_baseline.sql` | Hand-authored (transitional) | Raw baseline (partitioned parents) |
| `V3__pdl_api_company_enrichment.sql` | Hand-authored (transitional) | `pdl_api` baseline: company queue, cleaner + enrichment audits, driver views |
| `V4__ref_baseline.sql` | Hand-authored (transitional) | Ref baseline |
| `V5__ref_unique_indexes.sql` | Hand-authored (permanent) | `COALESCE(...)` UNIQUE indexes on `ref.city` / `ref.location`; DBML can't express them |
| `V6__integration_baseline.sql` | Hand-authored (transitional) | Integration baseline |
| `V7__staging_baseline.sql` | Hand-authored (transitional) | Staging baseline (PDL person surface) |
| `V8`…`V28` | Hand-authored | Staging / ref / integration / catalog additions and alters, plus the company-enrichment staging + integration tables |
| `V35__pdl_api_location_cleaner.sql`, `V36__pdl_api_school_cleaner.sql` | Hand-authored (transitional) | Location and school cleaner queues + audits |
| `R__function_project_pdl_deltas.sql` | Hand-authored (permanent) | Ledger projection function |
| `R__permissions.sql`, `R__roles.sql` | Hand-authored (permanent) | GRANT / role definitions |
| Future `R__view_*.sql`, `R__seed_*.sql` | Hand-authored (permanent) | Views; seed-from-public-standards data |

"Transitional" = hand-authored now, to be replaced by compiler output. "Permanent" = DBML structurally cannot express it. When the compiler ships, transitional files are regenerated and `flyway repair` reconciles checksums on existing local databases (or `make dev-reset`).

### Migration file-scoping convention

**One DBML file per schema. One baseline migration per schema. Additions ship as their own V_n.**

Three rules, in priority order:

1. **Every schema has exactly one DBML file** at `modeling/dbml/<schema>.dbml`. The DBML always reflects the schema's *current* state. The migration sequence is how-we-got-there.

2. **Each schema's first migration is its baseline** — one V_n file that creates the schema and its founding table set. Filename:
   - `V<n>__<schema>_baseline.sql` for whole-schema baselines (e.g. `V1__catalog_baseline`, `V2__raw_baseline`, `V4__ref_baseline`, `V6__integration_baseline`, `V7__staging_baseline`).
   - `V<n>__<schema>_<feature>.sql` allowed when the baseline introduces a coherent feature within an operational schema (e.g. `V3__pdl_api_company_enrichment.sql`). It is still the baseline; the name describes what it contains.

3. **Subsequent additions to a schema = new V_n per coherent unit**:
   - One new table → `V<n>__<schema>_<table>.sql` (`CREATE TABLE`).
   - One new feature (several tightly-coupled tables) → `V<n>__<schema>_<feature>.sql` (e.g. `V35__pdl_api_location_cleaner.sql`).
   - One ALTER → `V<n>__<schema>_<table>_<change>.sql`.
   - One sidecar (DBML-inexpressible feature on existing tables) → `V<n>__<schema>_<feature>.sql` (e.g. `V5__ref_unique_indexes.sql`).

   Always edit DBML in the same change to reflect the post-migration state.

**Consequence for design density**: schemas that benefit from upfront design should be fully designed before the baseline is applied, because every post-baseline addition is a separate migration.

**Re-baselining (future)**: once the scaffolding compiler ships, a schema's accumulated migrations can be squashed into a single regenerated baseline deterministically from current DBML. Until then, do NOT hand-squash migrations — subtle drift between a squashed file and what V1..V_n actually produced surfaces months later.

**Discipline that keeps re-baselining safe**: the whole V1..V_n sequence applied to an empty DB must produce exactly the current DBML state (see Requirements above).

**What DBML structurally cannot express** (and therefore lives in hand-authored migrations): views, materialized views, triggers, trigger functions, stored procedures, `COALESCE(...)` UNIQUE indexes, expression indexes (`lower(col)`), partial indexes (`WHERE status = 'pending'`), trigram / GIN / GiST / BRIN indexes, partitioning (raw schema), generated columns, row-level security, foreign tables, deferrable constraints, complex CHECK predicates.

### Postgres functions: repeatable migrations

Hand-authored Postgres functions (`raw.project_pdl_deltas`, future ones such as a reactivation detector or a stale-partition cleaner) share these properties: self-contained, tested in isolation, versioned via Flyway, called by name from Python. **dbt never calls them, and they never reference dbt artifacts.**

Each lives in its own file with Flyway's **`R__` repeatable prefix**:

```
modeling/flyway/migrations/
├── V1__catalog_baseline.sql
├── V2__raw_baseline.sql
├── ...
├── R__function_project_pdl_deltas.sql      # repeatable: function definition
└── R__function_<future>.sql
```

Tables hold data and need forward-only `V__` migrations. Functions are stateless — `CREATE OR REPLACE FUNCTION` is safe, and Flyway re-applies an `R__` file whenever its checksum changes. Edit the file in place, re-run Flyway, the new definition replaces the old. The same pattern covers views and triggers.

**Invocation**: functions are called from the Python processes over psycopg2 (e.g. `pdl_projection_runner.py` runs `SELECT raw.project_pdl_deltas(%s)`), inside a transaction so a RAISE rolls back the whole step.

### Modeling workflow

Every change to the data model follows the same order:

1. **ERD update.** Decide what's changing before writing code.
2. **Source mapping.** For each new attribute, identify the PDL field (`$.path`) that populates it and record it in the data-model docs.
3. **DBML + Flyway migration authored**, per the file-scoping convention.
4. **Reviewed and merged** together.
5. **dbt models updated** to the new shape; `on_schema_change='fail'` catches mismatches.
6. **Catalog parsers updated if needed** (rarely).

**Modeling precedes implementation.** Skipping ahead produces either *dbt-first* drift (a model references a column no migration created) or *migration-first-without-design* inconsistencies.

---

## 12. Open Items

Known open items:

- **OQ-3a — OPTED_OUT folder semantics.** Does a missing `OPTED_OUT_RECORDS` folder mean "none this month" or an upstream error? Treated as optional.
- **Reactivation detection.** A function that appends `pdl_inactive` rows with `reason='reactivated'` when a previously inactive pdl_id reappears in `data/` (Section 6).
- **`catalog.person_key_map`** — decide the identity signature normalization (case folding, whitespace, accent stripping) and wire it into `integration.person`.
- **Queue population as dbt models** — move the `pdl_api.*_input_list` INSERTs from ad-hoc SQL into dbt models fed by PDL staging.
- **Location / school cleaner consumption** — staging models that join cleaner results back to PDL rows (cleansing tier, doc 21).
- **Scaffolding compiler** (`modeling/scaffolding`) — DBML → Flyway / dbt generation and the drift check on generated files.
