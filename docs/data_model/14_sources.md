# 14. Sources — what feeds the integration schema

**Scope**: the data sources feeding `ref.*` and `integration.*`, the path each takes through the pipeline, what each contributes, and how source attribution is recorded on the model. Cross-reference: [13_person.md §7](13_person.md) for `catalog.person_key_map`; [PDL person schema](https://docs.peopledatalabs.com/docs/person-schema) for field definitions.

**Sources**: People Data Labs only, through two channels:

1. **PDL Person bulk delivery** — monthly person snapshots + delta files, read from S3 (or local MinIO).
2. **PDL API** — Company Enrichment plus the Company / Location / School Cleaner endpoints, called by `processing/pdl_api`.

---

## §1. Principles

1. **One natural key per conformed entity.** `pdl_id` for person and school, `pdl_company_id` for company. Cross-system identity (stable `internal_person_id`, any downstream-system ids) lives in the `catalog.person_key_map` ledger, never as columns on `integration.person`.
2. **PDL's emit shape is the baseline shape** of `integration.person`, `integration.experience`, `integration.person_education`, `integration.company`, `integration.school`, and every junction.
3. **Source attribution is kept where it is cheap**, so another source could be added later without reshaping tables (§4). PDL is the only source, so every attribution column carries a PDL value.
4. **No multi-source precedence machinery.** With one source there is nothing to reconcile at field level. The only "precedence" in the model is between the two PDL channels for company data (Enrichment over person-embedded company), handled by `COALESCE` in `integration/company.sql` — see [doc 08 §6.3](08_company.md).

---

## §2. PDL Person bulk delivery

**Role**: bulk person + employment + education + embedded company + location data. Source of the `pdl_id` natural key, and of millions of companies via `experience[].company`.

**Path**:

```
S3 / MinIO  ──Finder──▶  Loader (boto3 download → decompress → psycopg2 COPY FROM STDIN)
            ──▶ raw.pdl_person            (full snapshot; partitioned by part file; latest-only)
            ──▶ raw.pdl_merged_records    ─┐
                raw.pdl_deleted_records    ├─ PDL projection ─▶ catalog.pdl_id_aliases
                raw.pdl_opted_out_records ─┘                    catalog.pdl_inactive
            ──▶ dbt staging: staging.pdl_person_*_parsed ─▶ staging.pdl_person_*_unique
                (alias-resolved)
            ──▶ ref.* + integration.*
```

Runs and files are tracked in the catalog run-logging tables (`catalog.pdl_delivery`, `catalog.ingestion_run`, `catalog.ingestion_file`). See [design/15](../design/15_pdl_staging_design.md) for staging shape and [design/02 §10](../design/02_pipeline_design.md#10-catalog-logging) for what the catalog records.

**Volume**: a full delivery is millions of person records.

**Field-level reference**: the [PDL person schema](https://docs.peopledatalabs.com/docs/person-schema); see [requirements/01](../requirements/01_pipeline_requirements.md) for the bool-placeholder rule.

**Per-record freshness signals** (PDL emits these on most records) — carried on `integration.person`:
- `job_last_changed` — when the person's current job last changed
- `job_last_verified` — when PDL last verified the current employment
- `location_last_updated` — when PDL last updated location info

**Per-fetch metadata** (belongs at delivery grain, not row grain):
- `dataset_version` — uniform within a delivery; the delivery's schema version is recorded as `catalog.pdl_delivery.pdl_dataset_id`
- `operation_id` — PDL match-operation SHA-256 trace ID; not persisted (a per-record lineage table could carry it if needed)

**Confirmed unsourced on this subscription tier** (PDL doesn't deliver — dropped):
- `linkedin_connections`, `inferred_years_experience` — keys absent from the JSON on every record profiled
- `first_seen`, `num_sources`, `num_records` — same
- `certifications[]` — V10 dropped from staging; V16 dropped `integration.person_certification`
- `languages[]` — not delivered; `ref.language` / `integration.person_language` exist but stay empty
- `name_aliases[]` — never populated in the profiled delivery; V16 dropped `integration.person_name_alias`

**Confirmed bool-placeholders on this subscription tier** (PDL emits literal `"true"`/`"false"` strings — dropped in V16):
- Person: `mobile_phone`, `birth_date`, `birth_year`, `recommended_personal_email`, `location_street_address`, `location_address_line_2`, `street_addresses` (plural)
- Person social: `github_url`, `github_username`, `twitter_url`, `twitter_username`, `facebook_url`, `facebook_id`, `facebook_username`
- **Nested URL fields are CLEAN** (no placeholders found in a large sample): `$.experience[*].company.{linkedin_url, facebook_url, twitter_url, website}` and `$.education[*].school.{...}` — the bool-placeholder pattern is strictly a top-level-person-field phenomenon.

Full column mapping: [doc 13 §6](13_person.md).

---

## §3. PDL API

**Role**: fills what the person bulk delivery does not carry — full company records (Company Enrichment) and canonicalized company / location / school values (Cleaners). Implemented as a generic caller in `processing/pdl_api` (see [design/18](../design/18_pdl_api_generic_caller.md)); API key from the `PDL_API_KEY` env var.

**Path**: each endpoint has a queue table, a driver view, and an append-only audit table in the `pdl_api` schema. Workers claim queue rows, call PDL, write one audit row per call / per returned record, and finalize the queue status.

| Endpoint | Queue | Audit | Downstream |
|---|---|---|---|
| Company Enrichment (`/v5/company/enrich/bulk`) | `pdl_api.company_input_list` | `pdl_api.company_enrichment_call` | `staging.pdl_api_company_parsed` → `integration.company`, `integration.company_affiliation`, `ref.pdl_relationship` |
| Company Cleaner (`/v5/company/clean`) | `pdl_api.company_input_list` | `pdl_api.company_cleaner_call` | Resolves raw company names/URLs to a `pdl_company_id` ahead of enrichment |
| Location Cleaner (`/v5/location/clean`) | `pdl_api.location_input_list` | `pdl_api.location_cleaner_call` | Canonical location strings (no staging model consumes them yet; input for cleansing) |
| School Cleaner (`/v5/school/clean`) | `pdl_api.school_input_list` | `pdl_api.school_cleaner_call` | Canonical school / `pdl_school_id` (no staging model consumes them yet; input for cleansing) |

**Volume**: enrichment covers an operator-chosen subset of the person-embedded companies; it is operator-triggered, not every run.

**Company Enrichment contribution** (detail in [doc 08 §5.2](08_company.md)): 15 enrichment-only scalars, 8 jsonb multi-valued columns (NAICS, SIC, tags, alternative names/domains, funding stages, employee count by country, profiles), and `affiliated_entities[]` → `integration.company_affiliation`. Enrichment does not emit `industry_v2`; that stays person-tier only.

---

## §4. Source attribution in the model

Where the model records which source (or which PDL channel) produced a value — as it exists in `modeling/dbml/`:

| Column | Values | Meaning |
|---|---|---|
| `integration.company.source` | `'person_experience'` \| `'enrichment'` \| `'affiliation_stub'` | Which PDL channel produced the row; highest-fidelity wins. See [doc 08 §6.3](08_company.md). |
| `integration.experience_industry.source` | `'pdl'` | Per-edge attestation on the junction. Part of the junction's row so a second source could attest the same `(experience_id, industry_id)` edge without a schema change. |
| `ref.industry.source_type` | `'pdl'` | Where the industry name was first seen. |
| `integration.company.fetched_at` / `company_affiliation.dataset_version` | timestamp / PDL dataset version | Freshness of the enrichment response that asserted the row / edge. |

All other `integration.*` tables and junctions are PDL-only by construction and carry no source column.

---

## §5. Adding a source later

The model is single-source but deliberately leaves room. If another source is ever added, document it here with:

1. **Role** — what category of data it contributes (identity, enrichment, recency, attestation).
2. **Schema impact** — new columns at integration grain, new tables, or row-source-only (same shape as PDL)?
3. **Identity resolution** — natural key, `catalog.person_key_map` mapping, match logic.
4. **Column inventory** — per column: target table, whether it conflicts with a PDL value, and the merge pattern.
5. **Conflict resolution** — prefer a `source`-tagged junction row for multi-valued fields; a sibling column for an occasional scalar conflict; a field-attestation ledger only if conflicts multiply.

The principles in §1 are load-bearing; a new source should respect them, not work around them.
