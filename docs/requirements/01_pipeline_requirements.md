# Pipeline Requirements

**Status**: living document. Source of truth for **what** the pipeline does and why. Design and implementation (how) live in [`../design/02_pipeline_design.md`](../design/02_pipeline_design.md), [`../design/16_dbt_pipeline_layers.md`](../design/16_dbt_pipeline_layers.md), and the component design docs linked below.

Update this document when a requirement changes. Open items are listed in [design 02 §12](../design/02_pipeline_design.md#12-open-items).

---

## TLDR

**Purpose**: ingest People Data Labs (PDL) Person bulk deliveries, parse them into a typed staging layer, enrich and normalize companies / locations / schools through the PDL API, project everything into a normalized `ref.*` + `integration.*` data model, track PDL identity events across deliveries, and apply cleansing routines (prototyped as SQL; the target is a dbt tier upstream of integration).

**Source**: PDL is the only source.
- **PDL Person bulk**: monthly full snapshot plus delta folders (added / updated / deleted / merged / opted-out).
- **PDL API**: Company Enrichment (bulk) and the Company / Location / School Cleaner endpoints.

**Output**: a normalized `integration` schema (person, company, school, experience, education, and their junctions) backed by `ref.*` controlled vocabularies. Attribute updates overwrite; no attribute history is kept. Identity events (PDL merges, deletions, opt-outs) are kept in an identity ledger in `catalog.*`.

**Architecture**: stateless content rebuild plus a stateful identity ledger. Content tables rebuild every run; identity and audit tables persist across runs. The PDL API audit tables are the other stateful exception, kept so already-paid API calls are not repeated.

**Runtime**: local only. Docker Compose Postgres (`localhost:5432`), Flyway migrations, with dbt and the Python ingester run on the host in the `pdl_test` conda env; `make pipeline-pdl` runs ingest + dbt end to end.

**Not in scope**: real-time ingestion, attribute history, automatic merge reversal (splits), sub-monthly refresh, cloud deployment.

---

## Scope

### In scope

- Ingestion of PDL Person bulk deliveries from S3 (or a local MinIO bucket) into `raw.*`.
- Projection of PDL delta folders (merged / deleted / opted-out) into the identity ledger.
- Parsing PDL Person JSON into typed `staging.pdl_person_*_parsed` tables and deduplicated, alias-resolved `staging.pdl_person_*_unique` tables.
- PDL API calls: Company Enrichment and the Company / Location / School Cleaners, with queue, audit, and cost controls in the `pdl_api` schema, parsed into `staging.pdl_api_company_parsed`.
- `ref.*` controlled vocabularies and the `integration.*` normalized data model.
- Cleansing routines (normalization, invalid-value filters, dedup, canonical rollups) applied before data reaches `integration.*`.
- Stable internal person IDs and tracking of identity events over time.

### Globally out of scope

- **Real-time ingestion.** Everything is batch.
- **Push-based delivery.** Deliveries are pulled from S3 / MinIO.
- **Upstream data remediation.** If PDL ships bad data we flag it, filter it, or cleanse it on our side; we do not correct PDL.
- **Attribute history / SCD Type 2.** Integration overwrites on update. No "Jane's title was X in March, Y in April" is kept anywhere.
- **Automatic merge reversal (splits).** Merges are one-way; corrections are manual.
- **Schema evolution without code change.** New attributes require a DBML edit, a Flyway migration, and dbt model changes.
- **Cloud runtime.** The pipeline runs locally (Docker Compose + conda env). Real PDL deliveries can be read from S3 with standard AWS credentials, but nothing is deployed.

---

# Part I: Requirements

## 1. Purpose and Goals

1. **One normalized model of PDL Person data.** Persons, their work history, education, company associations, and locations are parsed out of PDL's nested JSON into normalized tables with foreign keys into shared reference vocabularies.
2. **Clean, canonical companies, locations, and schools.** PDL API enrichment and cleaners resolve free-text names to PDL canonical IDs and attributes; cleansing routines fix what PDL gets wrong.
3. **Track merges, deactivations, and reactivations over time.** PDL-internal merges, deletions, and opt-outs are recorded; a person who comes back keeps the same internal ID.
4. **Reproducible locally.** A fresh checkout plus `make dev-up` and `make pipeline-pdl` rebuilds the full model from a delivery (or the bundled sanitized fixture) with no cloud dependencies.

**Source extensibility**: PDL is the only source. Integration tables keep a `source` column where provenance matters (e.g. `integration.company.source`) so another source could be added later without reshaping the model.

---

## 2. Architecture Baseline

The pipeline uses a **stateless content rebuild with a stateful identity ledger**.

- **Content tables** (`staging.*`, `ref.*`, `integration.*`) are rebuilt fresh each run from the latest raw data. Attribute values are overwritten; no history is kept.
- **Identity ledger tables** (`catalog.pdl_id_aliases`, `catalog.pdl_inactive`, `catalog.person_key_map`, `catalog.merge_events`) persist across runs and accumulate identity events. They are never rebuilt from raw.
- **PDL API state** (`pdl_api.*` queue and call-audit tables) is a related stateful exception, kept across runs so already-paid API calls are not repeated on rebuild.

### Refresh patterns per layer

| Layer | Refresh pattern | Who populates |
|---|---|---|
| `raw.*` | Stateless rebuild (TRUNCATE + COPY per delivery file) | S3 Ingester (`processing/s3_ingester`) |
| `staging.*` (`_parsed` / `_unique`) | Stateless rebuild (TRUNCATE + INSERT per dbt run) | dbt models in `processing/dbt/models/staging/` |
| `ref.*` (controlled vocabularies) | Stateless rebuild (TRUNCATE + INSERT DISTINCT per dbt run) | dbt models in `processing/dbt/models/ref/` (not staging; see ADR-0005) |
| `integration.*` | Stateless rebuild (TRUNCATE + INSERT per dbt run) | dbt models in `processing/dbt/models/integration/` |
| `catalog.*` ledger (`pdl_id_aliases`, `pdl_inactive`, `person_key_map`, `merge_events`) | Stateful, append-only (status updates in place on `person_key_map`) | `raw.project_pdl_deltas()` from raw delta files (`person_key_map` is reserved and not populated) |
| `catalog.*` load audit (`pipeline_run`, `ingestion_run`, `ingestion_file`, `pdl_delivery`) | Stateful, append-only | Written by the ingester (Finder / Loader / `run.py`) |
| `pdl_api.*` (input lists, cleaner / enrichment call audit) | Stateful (queue status updated in place; call audit append-only) | PDL API callers (`processing/pdl_api`) |

Catalog (ledger + audit) and `pdl_api.*` are the only stateful subsystems. Everything else rebuilds every run.

Cross-references: `modeling/dbml/staging.dbml` header for the staging naming convention; [`../decisions/0005-ref-population-layer.md`](../decisions/0005-ref-population-layer.md) for stateless ref rebuild; [`../design/16_dbt_pipeline_layers.md`](../design/16_dbt_pipeline_layers.md) for layer mechanics and DAG ordering.

This architecture shapes the rest of this document:
- **Updates overwrite**; no attribute history (Section 6).
- **Deactivation removes the person from current-state integration tables**; the ledger keeps the identity and the audit trail (Section 7, ADR-0007).
- **Identity continuity** is meant to come from a stable `internal_person_id` in the ledger (Section 4; not yet wired, so `pdl_id` is the stable key).
- **Content corruption** is fixed by drop-and-rebuild; **ledger loss** is a critical incident (Section 12).

---

## 3. Data Sources

### 3.1 PDL Person (bulk delivery)

**Cadence**: monthly full load.

**Format**: gzipped CSV part files; each line is a single JSON object holding a full person record with nested experience, education, and company/school details. Nested elements can contain arrays.

**Bucket layout** (S3 for real deliveries; MinIO bucket `pdl-ingest-local` for local runs):

```
s3://<pdl-bucket>/
  <delivery_date>/                            -- e.g. 2026_04_22 (yyyy_mm_dd)
    data/                                     -- full snapshot
      part-NNNNN.csv.gz                       -- hundreds of part files; each line = one JSON object
    delta_data/                               -- absent on first delivery
      ADDED_RECORDS_MONTHLY_V_NN.N/           -- pdl_ids added since previous delivery (not consumed)
      DELETED_RECORDS_MONTHLY_V_NN.N/         -- pdl_ids deleted since previous delivery
      MERGED_RECORDS_MONTHLY_V_NN.N/          -- pdl_id merge events
      UPDATED_RECORDS_MONTHLY_V_NN.N/         -- pdl_ids whose records changed (not consumed)
      OPTED_OUT_RECORDS_MONTHLY_V_NN.N/       -- pdl_ids opted out (may be absent; see OQ-3a)
    COMPLETED                                 -- sentinel at the delivery root
```

Notes:
- One `COMPLETED` sentinel at the delivery root covers both `data/` and `delta_data/`. The Finder refuses to register a delivery without it.
- Delta folder names carry a PDL schema version suffix (`_V_NN.N`). The version does not drive pipeline behavior; deltas contain only pdl_ids. The Ingester pattern-matches folder names.
- The **first delivery** has `data/` only. Delta handling starts with the second delivery.

**Delta row shapes** (pdl_ids only, not full records):

- `ADDED_RECORDS`, `DELETED_RECORDS`, `UPDATED_RECORDS`, `OPTED_OUT_RECORDS`: `{"id": "<pdl_id>"}` (opted-out shape assumed; see OQ-3a)
- `MERGED_RECORDS`: `{"id": "<pdl_id>", "merged_to": "<pdl_id>"}`; `id` is the losing pdl_id, `merged_to` the winner.

**Delta usage**:

- `MERGED_RECORDS`: consumed. Populates `catalog.pdl_id_aliases` and `catalog.merge_events` (`event_type = 'pdl_merge'`).
- `DELETED_RECORDS`: consumed. Populates `catalog.pdl_inactive` with `reason = 'deleted'`.
- `OPTED_OUT_RECORDS`: consumed when present (`reason = 'opted_out'`). A missing folder means no events.
- `ADDED_RECORDS`, `UPDATED_RECORDS`: **not consumed.** The full snapshot in `data/` already carries the current values and stateless rebuild picks them up. They could later feed change-feed or freshness logic.

**Natural key**: `pdl_id`.

**Merge semantics**: PDL merges are authoritative. PDL re-merges across deliveries, so alias chains can be multi-hop (A → B → C) and occasionally cyclic (A → B, later B → A). Staging must resolve every alias chain to its terminal pdl_id and collapse 2-cycles deterministically (see [design 15, alias resolution](../design/15_pdl_staging_design.md#alias-resolution-in-pdl_person_unique)).

**Field-level freshness**: PDL emits freshness signals such as `job_last_changed`, `job_last_verified`, and `location_last_updated`. They are carried into `integration.person` as-is.

**Redacted fields**: on the subscription tier this pipeline was built against, several top-level person fields (street address, mobile phone, personal email, birth date, non-LinkedIn social URLs) arrive as `"true"` / `"false"` placeholders, never real values. Columns whose PDL source is a placeholder **must not exist** in staging or integration.

**Load path**: the Ingester downloads each object with boto3 (standard AWS credential chain / `AWS_PROFILE` for real S3; `AWS_ENDPOINT_URL` for MinIO), decompresses it, and streams it into the raw leaf partition with `COPY ... FROM STDIN` over psycopg2. Each file is TRUNCATE + COPY into its own leaf, so re-running a delivery is safe.

### 3.2 PDL API

Used for companies, locations, and schools. All calls go through the generic caller in `processing/pdl_api` (design: [`../design/18_pdl_api_generic_caller.md`](../design/18_pdl_api_generic_caller.md)).

| Endpoint | Caller | Queue (`pdl_api.*`) | Call audit (`pdl_api.*`) |
|---|---|---|---|
| `/v5/company/clean` | `CompanyCleanerCaller` | `company_input_list` (`cleaner_status`) | `company_cleaner_call` |
| `/v5/company/enrich/bulk` | `CompanyEnrichmentCaller` (bulk, ≤100 records per call) | `company_input_list` (`enrichment_status`) | `company_enrichment_call` |
| `/v5/location/clean` | `LocationCleanerCaller` | `location_input_list` | `location_cleaner_call` |
| `/v5/school/clean` | `SchoolCleanerCaller` | `school_input_list` | `school_cleaner_call` |

Enrichment responses are parsed by dbt into `staging.pdl_api_company_parsed`, which feeds `integration.company` and `integration.company_affiliation` (Section 9).

**Secrets**: `PDL_API_KEY` comes from the environment (local `.env`, gitignored). It is never committed.

---

## 4. Identity

### 4.1 PDL identity

- `pdl_id` is the natural key for a person.
- Every pdl_id read from `raw.pdl_person` is resolved through `catalog.pdl_id_aliases` to its current (terminal) pdl_id before deduplication. `staging.pdl_person_unique` holds **one row per current pdl_id**.
- Alias resolution must handle multi-hop chains and must not loop on cycles (bounded walk; cycle and hop-cap tests surface anomalies as warnings).

### 4.2 Stable internal person ID

- Each distinct person gets a stable `internal_person_id` in `catalog.person_key_map`. It never changes once assigned.
- `person_key_map.status` is `active`, `inactive`, or `merged_into`; `merged_into_id` is set exactly when status is `merged_into`.
- When PDL merges pdl_id A into B, the person behind A resolves to B's `internal_person_id`; A's entry is marked `merged_into` and a `merge_events` row is written.
- Correcting a bad merge is a manual operation on `catalog.person_key_map`, recorded as `event_type = 'manual_merge'` where relevant. Splits are not automated.

**Current implementation**: `integration.person.id` is a dbt-computed surrogate (`ROW_NUMBER() OVER (ORDER BY pdl_id)`, ADR-0010) and is **not** stable across rebuilds. `catalog.person_key_map` exists but is not populated; swapping the surrogate for its `internal_person_id` is deferred (ADR-0007, ADR-0010). Until then, `pdl_id` is the stable key consumers should join on. The rules above describe the target behavior.

**Identity signature**: `person_key_map.identity_signature` is the lookup key used to find or mint an `internal_person_id`. With PDL as the only source, the alias-resolved `pdl_id` is the natural anchor; the exact signature construction is an open design decision (see [design 02 §12](../design/02_pipeline_design.md#12-open-items)). Whatever is chosen, signature composition is a stability contract: changing it between runs makes existing persons look new, so treat changes as breaking.

---

## 5. Identity Ledger

The identity ledger is the family of `catalog` tables that record identity events and stable IDs. **Stateful; persists across runs.** Table shapes live in `modeling/dbml/catalog.dbml`; the projection mechanics live in [`../design/02_pipeline_design.md`](../design/02_pipeline_design.md).

| Table | Holds | Populated by | Semantics |
|---|---|---|---|
| `catalog.pdl_id_aliases` | `old_pdl_id → current_pdl_id`, `observed_at`, `delivery_date` | `raw.project_pdl_deltas()` from `MERGED_RECORDS` | Append-only. Read by staging for alias resolution. |
| `catalog.pdl_inactive` | `pdl_id`, `reason` (`deleted` / `opted_out` / `reactivated`), `observed_at`, `delivery_date` | `raw.project_pdl_deltas()` from `DELETED_RECORDS` / `OPTED_OUT_RECORDS` (`reactivated` is reserved; nothing writes it, Section 7) | Append-only audit log. Latest event per pdl_id is its current state. |
| `catalog.person_key_map` | `internal_person_id`, `identity_signature`, `status`, `merged_into_id`, `first_seen_at`, `last_seen_at` | Nothing yet (reserved; Section 4.2) | New persons appended; `status` / `merged_into_id` updated in place. `internal_person_id` never changes. Canonical current identity state. |
| `catalog.merge_events` | `event_type` (`pdl_merge` / `identity_resolution_merge` / `manual_merge`), `losing_id`, `winning_id`, `observed_at`, `notes` | `raw.project_pdl_deltas()` (pdl_merge); manual corrections | Append-only audit of every merge. |

Requirements:
- Projection for a delivery must be **idempotent** (re-running for the same `delivery_date` inserts nothing new) and **atomic** (it fails as a whole).
- Projection must only attribute events to the delivery that actually shipped them.
- The ledger is never truncated by a content rebuild.

### Pipeline flow through the ledger

```
PDL delivery (S3 / MinIO)
        |
        v
  Raw ingestion (Finder -> Loader)
    - data/            -> raw.pdl_person (leaf per part file)
    - MERGED_RECORDS   -> raw.pdl_merged_records
    - DELETED_RECORDS  -> raw.pdl_deleted_records
    - OPTED_OUT_RECORDS-> raw.pdl_opted_out_records
        |
        v
  Ledger projection (raw.project_pdl_deltas)
    - merged   -> pdl_id_aliases + merge_events(pdl_merge)
    - deleted, opted_out -> pdl_inactive
        |
        v
  Staging (dbt)
    - parse JSON -> pdl_person_*_parsed
    - resolve pdl_ids through pdl_id_aliases (recursive), dedupe -> pdl_person_*_unique
        |
        v
  PDL API (cleaners + company enrichment) -> staging.pdl_api_company_parsed
        |
        v
  Cleansing (target: dbt tier upstream of integration;
             today: SQL routines run by hand, Section 11)
        |
        v
  ref.* + integration.* (dbt)
```

---

## 6. Update Semantics

Integration rows are **overwritten** when source data changes. No attribute history is kept.

- Jane's title changing from "Senior Engineer" to "Principal Engineer" in PDL → the next run rebuilds integration with "Principal Engineer". The old value is gone.
- Nested elements (experience, education) are replaced wholesale per person on each rebuild; no entry-level diff is kept.
- Jane's identity stays the same across the change (`pdl_id`; `internal_person_id` once wired, Section 4.2).

Consumers who need change history must diff their own snapshots. The pipeline does not emit attribute-change feeds.

---

## 7. Deactivation and Reactivation

### Deactivation

- pdl_ids in `DELETED_RECORDS` or `OPTED_OUT_RECORDS` are written to `catalog.pdl_inactive` with the matching `reason`. (Once `person_key_map` is populated, its `status` also becomes `inactive`.)
- A deactivated pdl_id is no longer in the `data/` snapshot, so it drops out of `staging.pdl_person_unique` and therefore out of `integration.*` on the next rebuild. No `status` column exists on integration tables: per [ADR-0007](../decisions/0007-integration-current-state-ledger-history.md), `integration.*` holds current state only and the ledger holds identity and history.
- Opted-out persons must not reappear in integration unless PDL ships them again in a later snapshot.

### Reactivation

If a previously-inactive pdl_id reappears in a later `data/` snapshot without being flagged inactive in that delivery:
- Append a `catalog.pdl_inactive` row with `reason = 'reactivated'`.
- Flip `catalog.person_key_map.status` from `inactive` back to `active`.
- Reuse the same `internal_person_id`; the person reappears in integration with their original ID.

**Current implementation**: reactivation detection is not implemented. `raw.project_pdl_deltas()` writes deactivation events only, and nothing writes `reason = 'reactivated'`. Because integration is rebuilt from the snapshot, a reappearing pdl_id does reappear in `integration.person`; what is missing is the ledger event (and, once `person_key_map` is populated, the status flip).

---

## 8. Staging (parse + dedupe)

- **Parse**: dbt models `staging.pdl_person_*_parsed` flatten the raw JSON (person, experience, education, companies, schools, addresses) into typed columns. Column shapes are fixed by `modeling/dbml/staging.dbml`; dbt runs with `on_schema_change='fail'`, so DBML, Flyway DDL, and the dbt SELECT must agree.
- **Unique**: `staging.pdl_person_*_unique` deduplicate on each entity's natural key and resolve pdl_ids through the alias ledger. Dedup ordering is a uniform placeholder (`loaded_at DESC, partition_id DESC`) until real data shows a better rule.
- **No `_staged` tier for PDL**: inactive persons are already absent from the snapshot, so integration reads `_unique` directly.
- **Drop dead columns**: columns with no real PDL values (placeholders, always-empty fields) are removed rather than carried.
- **Tests**: every `_unique` table has a `unique(natural_key)` test; alias-chain anomalies (cycles, hop-cap hits) are surfaced by warn-level singular tests.

Design: [`../design/15_pdl_staging_design.md`](../design/15_pdl_staging_design.md).

---

## 9. PDL API Enrichment and Cleaners

- **Queue-driven**: every API pass reads pending rows from its `pdl_api.*_input_list` queue (via a driver view), claims them with a `worker_id`, calls PDL, writes one audit row per record, and sets a terminal queue status. Stale claims can be reclaimed.
- **Never pay twice**: queue status and call audit persist across rebuilds. A `pdl_company_id` already enriched in a bulk batch marks its siblings `skipped_already_enriched`. Status transitions stay reversible so a later refresh can reset rows to `pending`.
- **Rate limits and cost caps**: requests-per-minute and daily / monthly credit caps are set per caller, not globally, because PDL limits vary by endpoint and plan. Bulk enrichment never sends more than 100 records per call.
- **Retry**: 429 and 502/503/504 responses and network errors retry with bounded backoff (honoring `Retry-After`); 200 / 404 / other 4xx are final answers and are audited as such.
- **Cleaner order**: company names are cleaned (resolved to a `pdl_company_id`) before enrichment; location and school cleaners resolve free-text locations and school names to PDL canonical values.
- **Parse responses in dbt**: enrichment JSON is parsed into `staging.pdl_api_company_parsed`; integration never reads raw API JSON.
- **No API calls in tests.** All PDL calls in tests are mocked. Live calls are allowed only in tests marked `pdl_smoke`, which are skipped unless `PDL_API_KEY` is set and are never part of a default run.

---

## 10. Data Model (`ref.*` + `integration.*`)

- **`ref.*`** holds controlled vocabularies discovered from PDL data: place hierarchy (`continent`, `country`, `state_province`, `city`, `metro`, `location`), `industry` / `industry_v2`, job-title class / role / subrole, `seniority_level`, `skill`, `interest`, `language`, `pdl_relationship`. Populated by their own dbt layer (ADR-0005) with dbt-computed surrogate IDs (ADR-0008).
- **`integration.*`** holds the normalized entities and junctions: `person`, `company`, `company_affiliation`, `school`, `experience`, `person_education`, and junctions such as `person_location`, `person_country`, `person_state_province`, `person_skill`, `person_interest`, `person_language`, `experience_location`, `experience_industry`, `experience_seniority_level`.
- **DBML is the contract** (ADR-0001): `modeling/dbml/<schema>.dbml` defines every column; Flyway migrations are derived from it; dbt models must match it exactly.
- **Foreign keys** are enforced at integration only (ADR-0002) and are dropped / recreated around rebuilds (ADR-0009).
- **Company provenance**: `integration.company.source` records the highest-fidelity origin (`enrichment` > `person_experience` > `affiliation_stub`).
- **PII**: no birth dates, mobile phones, or personal email arrays in integration.

Entity specs: [`../data_model/13_person.md`](../data_model/13_person.md), [`../data_model/08_company.md`](../data_model/08_company.md), [`../data_model/12_location.md`](../data_model/12_location.md), [`../data_model/10_reference_tables.md`](../data_model/10_reference_tables.md).

---

## 11. Cleansing

PDL data has known defects that must be corrected before it reaches `integration.*`. The rules are developed and proven in [`../pdl_data_cleansing/`](../pdl_data_cleansing/) and are to be implemented as dbt models at a `_cleaned` staging tier upstream of integration ([`../design/21_cleansing_layer_design.md`](../design/21_cleansing_layer_design.md)).

Required rule families:
- **Normalization functions** (IMMUTABLE, reusable): company names and brand cores, person names, job titles, locations, LinkedIn URLs and slugs, free-text prose.
- **Invalid-value filters**: garbage / placeholder person names; PDL "broken" company canonicals (role or occupation tokens that PDL fused into bogus company entities).
- **Dedup**: persons sharing a normalized LinkedIn URL; duplicate experience and education entries.
- **Canonical rollups**: school name variants to a canonical school; degree strings to degree families; company hierarchy (parent / child edges matched to PDL company IDs) feeding `integration.company_affiliation`.

Requirements:
- Cleansing runs on every rebuild and is deterministic (same input, same output).
- Raw values stay available in staging; cleansing produces new columns or tables rather than mutating `raw.*`.
- Every rule has a measurable effect that can be checked (rows changed / removed per run).

---

## 12. Refresh, Running, and Recovery

### Refresh cadence

- **PDL Person**: once per delivery (monthly), run on demand once the delivery's `COMPLETED` sentinel exists.
- **PDL API**: after the Person load, by hand (`make clean-pdl`, `make enrich-pdl`); only pending queue rows are called.
- Content layers rebuild in full each run; dbt tag selectors (`make dbt-<tag>`) rebuild a subset during development.

### Running locally

- `make dev-up` starts Postgres, applies Flyway migrations, and loads a sanitized PDL fixture.
- `make dev-up-ingester` adds MinIO (bucket `pdl-ingest-local`); `make ingest-pdl` runs Finder → Loader → ledger projection.
- `make dbt-pdl` builds staging and downstream; `make pipeline-pdl` runs ingest + dbt.
- Configuration comes from environment variables / a local `.env` (`DATABASE_URL`, `PDL_API_KEY`, `AWS_PROFILE` / `AWS_ENDPOINT_URL`). No secrets in files.

### Concurrency

Only one delivery is processed at a time. Running two loads concurrently against the same raw tables is not supported.

### Recovery

- **Content corruption**: drop and rebuild the affected content layers from raw; one rebuild cycle.
- **Ledger corruption**: `pdl_id_aliases`, `pdl_inactive`, and `merge_events` can be re-projected from archived delta files. `person_key_map` **cannot** be rebuilt from source data; losing it means new IDs for everyone. Back it up before destructive operations (e.g. `make dev-reset` drops all volumes).
- **PDL API state**: losing `pdl_api.*` means re-paying for calls. Back it up alongside the ledger.

---

## 13. Data Quality and Observability

- dbt tests (uniqueness, not-null, relationships, accepted values, singular tests) run as part of every build.
- Load history is recorded in the `catalog.*` audit tables (`ingestion_run`, `ingestion_file`, `pdl_delivery`); dbt run results live in dbt's own `target/` artifacts.
- Python components log to stdout; container (Postgres / Flyway / MinIO) logs are available via `make dev-logs`.
- Tests follow the tiered plan in [`../design/07_test_plan.md`](../design/07_test_plan.md). Tests must run without AWS credentials, network access, or real PDL calls.

---

# Part II: Open Questions

**OQ-3a: OPTED_OUT folder semantics**
- Deliveries seen so far have included ADDED, DELETED, MERGED, and UPDATED folders but no OPTED_OUT folder.
- Design default: a missing folder means no opt-out events this delivery (no alert).
- Alternatives: (B) the folder should always be present and its absence is an upstream error; (C) it is only delivered when volume is meaningful, or opt-outs are folded into DELETED.
- Confirm with PDL. Revisit the default if PDL says otherwise.

Further open items are listed in [design 02 §12](../design/02_pipeline_design.md#12-open-items).

---

# Part III: Glossary

- **pdl_id**: PDL's person identifier; the natural key for a person.
- **alias chain**: sequence of PDL merges (A → B → C) resolved to a terminal pdl_id.
- **internal_person_id**: the pipeline's stable surrogate person key, assigned in `catalog.person_key_map`.
- **identity_signature**: deterministic lookup key in `person_key_map` used to find or mint an `internal_person_id`.
- **identity ledger**: the stateful `catalog` tables tracking identity events and stable IDs (`pdl_id_aliases`, `pdl_inactive`, `person_key_map`, `merge_events`).
- **data/**: per-delivery folder with the full person snapshot.
- **delta_data/**: per-delivery folder with change-event subfolders (`ADDED_RECORDS_*`, `DELETED_RECORDS_*`, `MERGED_RECORDS_*`, `UPDATED_RECORDS_*`, `OPTED_OUT_RECORDS_*`).
- **`_parsed` / `_unique`**: staging tiers: typed flatten of raw JSON, then deduplicated and alias-resolved.
- **`_cleaned`**: staging tier where cleansing rules are applied before integration.
- **PDL Cleaner**: PDL API endpoints that resolve free-text company / location / school values to PDL canonical values.
- **PDL Company Enrichment**: PDL API endpoint returning full company records for a resolved company.
- **stateless content rebuild, stateful identity ledger**: the pipeline's architecture (Section 2).
