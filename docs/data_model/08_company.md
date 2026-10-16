# Company Schema — Normalized Relational Model

**Status:** Implemented (V28). Includes the PDL relationship model: stub-row pattern, `ref.pdl_relationship` ref table, `profiles[]` jsonb column, nullable `status_id` / `catalyst_id` / `dataset_version` on the junction. 3-value `source` enum (`person_experience` | `enrichment` | `affiliation_stub`).
**Person-tier source:** `raw.pdl_person.experience[].company` (PDL Person bulk delivery) — the 12 scalar columns shared with enrichment.
**Enrichment source:** PDL Company Enrichment API (`processing/pdl_api`) — populates the 15 enrichment-only scalar columns + 8 jsonb arrays + `integration.company_affiliation` junction. Lands via `pdl_api.company_enrichment_call` → `staging.pdl_api_company_parsed` → `integration.company` (LEFT JOIN + COALESCE merge with stub-insert pattern for orphan affiliated companies).
**PDL schema docs:**
- Person (`experience.company`): https://docs.peopledatalabs.com/docs/person-schema
- Company Enrichment: https://docs.peopledatalabs.com/docs/company-schema
- Premium Bundle (parent/subsidiary fields): https://docs.peopledatalabs.com/docs/company-data-field-bundles
**Companion docs:**
- [doc 18 — PDL API generic caller](../design/18_pdl_api_generic_caller.md) — operational workflow (queue tables, views, workers, trigger model, DAG order).
- [doc 10 — Canonical reference tables](10_reference_tables.md) — `ref.country` and friends. **`ref.naics_code` / `ref.sic_code` / `ref.mic_exchange` are deliberately not created — NAICS/SIC/MIC data lives as jsonb on `integration.company` (§1 scope decisions).**
- [doc 11 — PDL company field change buckets](11_pdl_company_field_change_buckets.md) — which fields change how often (informs future re-enrichment policy).
- [doc 12 — Location & address schema](12_location.md) — canonical place hierarchy.
- [doc 13 — Person schema](13_person.md) — `integration.experience.company_id` FKs into this table.
- [ADR-0011](../decisions/0011-loader-discovered-ref-tables.md) — loader-discovered ref layer; rejected seeded/drift detection.

---

## 1. Purpose

Model the conformed Company entity. **`integration.company` is sized to hold the union of fields PDL emits across multiple sources:**

- `person.experience[].company.*` — 12 scalar fields (name, size, founded, industry, type, website, social URLs, ticker, location). The lighter shape PDL embeds inside person records. Covers millions of companies in a full delivery.
- PDL Company Enrichment — superset of the above + 15 enrichment-only scalars (summary, headline, employee_count, inferred_revenue, mic_exchange, parent IDs, funding details, dataset_version, likelihood) + 8 multi-valued fields stored as jsonb (NAICS, SIC, tags, alternative_names, alternative_domains, funding_stages, employee_count_by_country, profiles) + relational data (`affiliated_entities[]` populating `integration.company_affiliation`). Only the operator-chosen subset that has been enriched.
- **Stub rows** — companies referenced as `affiliated_entities[].affiliated_id` by an enriched company but not otherwise in our data. Carry `pdl_company_id` + `name` + nothing else; preserve referential integrity for the affiliation junction and let graph queries traverse beyond enriched nodes.

**All three sources funnel into the same `integration.company` row.** One row per distinct `pdl_company_id`. The dbt model unions all three source sets and uses LEFT JOINs + COALESCE to pick highest-fidelity values per shared column. See §6.3 + §6.4 below for the merge semantics; [doc 18 — PDL API generic caller](../design/18_pdl_api_generic_caller.md) for the caller-side workflow.

**Scope decisions:**

- Multi-valued enrichment data (NAICS / SIC / tags / etc.) lands as **jsonb arrays on `integration.company`**, not as separate junction tables.
- `ref.naics_code`, `ref.sic_code`, `ref.mic_exchange` are NOT being created.
- Loader-discovered ref layer; **no seeded ref tables**. The only ref table added for enrichment is `ref.pdl_relationship`. (See [ADR-0011](../decisions/0011-loader-discovered-ref-tables.md).)
- **Stub-insert pattern** for orphan affiliated companies — preserves graph integrity vs. INNER-JOIN-drop.
- Deferred: PDL Parent Subsidiary Details extension (`status` / `catalyst` / `start_date` / `end_date` / `citations`); `ownership_edge` derived layer; stable internal company IDs; re-enrichment cycle.

This is the design contract. Operational implementation lives in [doc 18](../design/18_pdl_api_generic_caller.md).

---

## 2. Design Principles

1. **One `integration.company` sized for the union of all sources.** Every scalar PDL emits gets a column. Multi-valued enrichment fields are jsonb arrays on the same table. Hierarchy + affiliations live in the `integration.company_affiliation` junction.

2. **Stateless rebuild via single-pass LEFT JOIN + COALESCE merge** (not upsert). Every pipeline run TRUNCATEs `integration.company` and INSERTs from a single SELECT that LEFT JOINs all three source sets (person.experience, enrichment, affiliated_entities for stubs). Shared columns use `COALESCE(enrichment, person_experience, affiliated_display_name)`. Enrichment-only columns: enrichment value or NULL. `source` column computed at SELECT time via CASE — highest-fidelity tier wins (see §6.3).

3. **Bigint surrogate PK + `pdl_company_id` as natural key.** `integration.company.id` is `bigint` PK; dbt-computed via `ROW_NUMBER() OVER (ORDER BY pdl_company_id)` per [ADR-0010](../decisions/0010-extend-dbt-computed-surrogate-ids-to-integration.md). PDL's opaque id lives in `pdl_company_id text NOT NULL UNIQUE`. All FKs reference the surrogate.

4. **Address inline on `integration.company`** (V24 Option C). 1:1 cardinality (every company in a profiled full delivery has exactly one distinct address) — no separate address table earns its keep. Latitude / longitude / postal_code / street_address / address_line_2 + `location_id` (FK to `ref.location`) live directly on `integration.company`. Same Option C pattern as `integration.person` (V20).

5. **Stateless rebuild — no history.** Project-wide requirement ([requirements/01 §2](../requirements/01_pipeline_requirements.md)). One row per `pdl_company_id` per rebuild; surrogate IDs not stable across rebuilds. Identity continuity for downstream consumers comes from `pdl_company_id` (natural key) or a future `catalog.company_key_map.internal_company_id` (deferred — see §9).

6. **Source provenance via 3-value enum.** `integration.company.source` carries `'person_experience'` | `'enrichment'` | `'affiliation_stub'`. Highest-fidelity tier wins via CASE: `enrichment > person_experience > affiliation_stub`. See §6.3.

7. **Stub-insert preserves referential integrity for the affiliation graph.** When PDL emits `affiliated_entities[]` pointing at companies not in our person.experience or enrichment sets, we insert a minimal stub row in `integration.company` (id + pdl_company_id + name + source + timestamps; all else NULL). Junction INNER JOINs always resolve; no silent data loss. See §6.4.

8. **Stubs are ephemeral.** A stub row exists only as long as some currently-staged enrichment response references it in `affiliated_entities[]`. Re-enrichment that no longer references the company drops the stub from the next rebuild. No accumulation. See §6.4.

---

## 3. Entity-Relationship Overview

One company table + one junction (V28) + one new ref table (V28) + FKs into shared place / industry dimensions.

```
╔═══════════════════════════════════════════════════════════════════════╗
║  integration.company  ── one row per PDL company                      ║
║  ───────────────────                                                  ║
║    PK   id              bigint, surrogate                             ║
║    UQ   pdl_company_id  PDL natural key                               ║
║    FK   location_id     → ref.location.id                             ║
║    FK   industry_id     → ref.industry.id                             ║
║    FK   industry_v2_id  → ref.industry_v2.id      (person.exp only)   ║
║         latitude / longitude / postal_code        (inline V24)        ║
║         street_address / address_line_2           (inline V24)        ║
║    self immediate_parent_id, ultimate_parent_id   (enrichment denorm) ║
║         source                                                        ║
║           ∈ {person_experience, enrichment, affiliation_stub}         ║
║                                                                       ║
║    --- enrichment-only scalars ---                                    ║
║         display_name, linkedin_slug, mic_exchange, summary, headline, ║
║         employee_count, inferred_revenue, total_funding_raised,       ║
║         latest_funding_stage, last_funding_date,                      ║
║         number_funding_rounds, dataset_version, likelihood            ║
║                                                                       ║
║    --- V28 jsonb columns (multi-valued enrichment) ---                ║
║         naics_codes               jsonb  (rich PDL classification)    ║
║         sic_codes                 jsonb  (rich PDL classification)    ║
║         tags                      jsonb                               ║
║         alternative_names         jsonb                               ║
║         alternative_domains       jsonb                               ║
║         funding_stages            jsonb                               ║
║         employee_count_by_country jsonb                               ║
║         profiles                  jsonb  (multi-platform URLs)        ║
╚═══════════════════════════════════════════════════════════════════════╝

           │ self-FK (immediate_parent_id, ultimate_parent_id)
           ▼
        (same integration.company)

╔═══════════════════════════════════════════════════════════════════════╗
║  integration.company_affiliation  ── parent / subsidiary M:N (V28)    ║
║  ─────────────────────────────────                                    ║
║    FK   subject_company_id    → integration.company.id  (NOT NULL)    ║
║    FK   affiliated_company_id → integration.company.id  (NOT NULL)    ║
║    FK   relationship_id       → ref.pdl_relationship.id (NOT NULL)    ║
║    FK   status_id             → ref.pdl_relationship_status.id        ║
║                                                      (nullable —      ║
║                                                  reserved for future) ║
║    FK   catalyst_id           → ref.pdl_relationship_catalyst.id      ║
║                                                      (nullable —      ║
║                                                  reserved for future) ║
║         dataset_version       text                                    ║
║    PK   (subject_company_id, affiliated_company_id, relationship_id)  ║
╚═══════════════════════════════════════════════════════════════════════╝

╔═══════════════════════════════════════════════════════════════════════╗
║  ref.pdl_relationship  ── a handful of rows, loader-discovered (V28)  ║
║  ────────────────────                                                 ║
║    PK   id            bigint                                          ║
║    UQ   relationship  text                                            ║
║                                                                       ║
║  Loader-discovered from staging.pdl_api_company_parsed                ║
║  $.affiliated_entities[].relationship. Observed values:               ║
║  direct_subsidiary | indirect_subsidiary | immediate_parent           ║
║  | ultimate_parent.                                                   ║
╚═══════════════════════════════════════════════════════════════════════╝

Place dimensions (see doc 12):
  ref.country · ref.state_province · ref.city · ref.metro · ref.location

Industry dimensions:
  ref.industry · ref.industry_v2
```

**Why the parent FK denorm is intentional.** `immediate_parent_id` / `ultimate_parent_id` on `integration.company` duplicate data also in `company_affiliation` (rows with `relationship = 'immediate_parent'` / `'ultimate_parent'`). Same data, two access patterns. Downstream consumers can always compute parent fields from `company_affiliation` — so keeping the scalars here is cheap (only a minority of enriched companies populate them) and saves a JOIN on common queries. Redundancy is intentional.

---

## 4. Table-by-Table Specification

Notation: `PK` primary key, `FK` foreign key, `*` not-null. **Source** indicates which sources populate the value:
- `person.experience` — sourced from `staging.pdl_person_experience_unique` (present for every company seen in person data)
- `enrichment` — sourced from `staging.pdl_api_company_parsed` (the enriched subset)
- `affiliation_stub` — only the row's `pdl_company_id` + `name` (from `affiliated_entities[].display_name`); all other columns NULL
- `both` — either person.experience or enrichment can populate; enrichment wins via COALESCE
- `system` — pipeline metadata

### 4.1 `integration.company`

| Column | Type | Source | Notes |
|---|---|---|---|
| `id` * | `bigint` | system | PK. dbt-computed via `ROW_NUMBER()`. |
| `pdl_company_id` * | `text` | both / stub | **UNIQUE NOT NULL**. PDL's opaque id. Universal natural key. |
| `source` * | `text` | system | `'person_experience'` \| `'enrichment'` \| `'affiliation_stub'`. CASE at SELECT time: highest tier wins (see §6.3). |
| `name` | `text` | both / stub | `COALESCE(enrichment.name, person_experience.company_name, affiliated.display_name)` — stubs get the display_name from `affiliated_entities[]`. |
| `size` | `text` | both | COALESCE. PDL canonical band (`"10001+"`, `"51-200"`, …). |
| `founded` | `smallint` | both | Founding year. COALESCE. |
| `industry_id` | `bigint` | both | FK → `ref.industry.id` (V16). Resolved from `COALESCE(enrichment.industry, person_experience.company_industry)`. |
| `industry_v2_id` | `bigint` | person.experience | FK → `ref.industry_v2.id`. PDL Enrichment doesn't emit `industry_v2` (verified against enrichment responses). |
| `type` | `text` | both | `public` \| `private` \| `educational` \| `non_profit` \| `government`. COALESCE. |
| `website` | `text` | both | COALESCE. |
| `linkedin_id` | `text` | both | COALESCE. |
| `linkedin_url` | `text` | both | COALESCE. |
| `facebook_url` | `text` | both | COALESCE. |
| `twitter_url` | `text` | both | COALESCE. |
| `ticker` | `text` | both | Populated only if `type='public'`. COALESCE. |
| `display_name` | `text` | enrichment | Human-facing name. NULL for non-enriched. |
| `linkedin_slug` | `text` | enrichment | NULL for non-enriched. |
| `mic_exchange` | `text` | enrichment | Plain `text` — no FK (scope decision, §1). |
| `summary` | `text` | enrichment | |
| `headline` | `text` | enrichment | |
| `employee_count` | `int4` | enrichment | |
| `inferred_revenue` | `text` | enrichment | Band string (`"$10B+"`). |
| `immediate_parent_id` | `bigint` | enrichment | Self-FK → `integration.company.id`. Source: `response_json->>'immediate_parent'` (text scalar — PDL emits as string, NOT a nested object). Resolved via LEFT JOIN. NULL when parent isn't in our integration.company set. Populated for a minority of enriched companies. |
| `ultimate_parent_id` | `bigint` | enrichment | Self-FK. Same shape as `immediate_parent_id`. |
| `total_funding_raised` | `bigint` | enrichment | USD. |
| `latest_funding_stage` | `text` | enrichment | |
| `last_funding_date` | `date` | enrichment | |
| `number_funding_rounds` | `smallint` | enrichment | |
| `dataset_version` | `text` | enrichment | PDL `dataset_version`. |
| `likelihood` | `smallint` | enrichment | PDL match confidence (0-10). |
| `naics_codes` | `jsonb` | enrichment | **V28.** Array of PDL NAICS classification objects: `{sector, naics_code, sub_sector, industry_group, naics_industry, national_industry}`. Store the full element shape — don't flatten. Usually populated. |
| `sic_codes` | `jsonb` | enrichment | **V28.** Array of `{sic_code, major_group, industry_group, industry_sector}`. Usually populated. |
| `tags` | `jsonb` | enrichment | **V28.** Array of bare strings. Often populated. |
| `alternative_names` | `jsonb` | enrichment | **V28.** Array of bare strings. |
| `alternative_domains` | `jsonb` | enrichment | **V28.** Array of bare strings. |
| `funding_stages` | `jsonb` | enrichment | **V28.** Array of bare strings — per-round history. |
| `employee_count_by_country` | `jsonb` | enrichment | **V28.** Object: `{country_name: count}`. |
| `profiles` | `jsonb` | enrichment | **V28.** Array of multi-platform social URLs (LinkedIn, Twitter, Facebook, Crunchbase, etc.). Free-text network names inside the array — not normalized. |
| `location_id` | `bigint` | both | FK → `ref.location.id`. Resolved via the 4-way ref chain from `COALESCE(enrichment.location.*, person_experience.company_location.*)`. See [doc 12](12_location.md). |
| `latitude` | `numeric(9,6)` | both | Parsed from PDL `location.geo`. V24 Option C — inline. COALESCE on the geo string. |
| `longitude` | `numeric(9,6)` | both | Same. |
| `postal_code` | `text` | both | PDL `location.postal_code`. COALESCE. |
| `street_address` | `text` | both | Present for a large share of person.experience companies; enrichment fills it for enriched ones. |
| `address_line_2` | `text` | both | COALESCE. |
| `fetched_at` | `timestamptz` | system | Enrichment row: `pdl_api.company_enrichment_call.called_at`. Non-enriched: pipeline run timestamp. Stub: pipeline run timestamp. |

**Indexes** (post-V23 trim): PK on `id`; `UNIQUE (pdl_company_id)`; btree on `name`, `website`, `location_id`, `industry_id`. **4 secondary + PK + UNIQUE = 6 indexes total**, under the 8-per-table convention. (`ticker`, `linkedin_id`, `industry_v2_id`, parent FKs dropped in V23 — re-add via additive migration if a real consumer query emerges.)

**Stub row shape.** When `source = 'affiliation_stub'`, the row populates only: `id`, `pdl_company_id`, `name` (from `affiliated_entities[].display_name`), `source`, `fetched_at`, `timestamp_created`, `timestamp_modified`. All other scalars + all jsonb cols + parent FKs are NULL. Consumers should filter `source != 'affiliation_stub'` when they need rich data; stubs exist for referential integrity, not display.

### 4.2 `integration.company_affiliation` (V28)

PDL emits company hierarchy + parent/subsidiary relationships as `$.affiliated_entities[]` in the enrichment response. Each element is `{affiliated_id, display_name, relationship}`. One row per element.

| Column | Type | Notes |
|---|---|---|
| `subject_company_id` * | `bigint` | FK → `integration.company.id`. The company whose enrichment response carried this affiliation. |
| `affiliated_company_id` * | `bigint` | FK → `integration.company.id`. The other side. Resolved via JOIN: `affiliated_entities[].affiliated_id` (text pdl_company_id) → `integration.company.pdl_company_id` → `id`. Always resolves under the stub pattern (§6.4). |
| `relationship_id` * | `bigint` | FK → `ref.pdl_relationship.id`. |
| `status_id` | `bigint` | FK → `ref.pdl_relationship_status.id`. **Nullable.** Reserved for the future Parent Subsidiary Details extension; PDL doesn't emit it in the bundle this pipeline uses. |
| `catalyst_id` | `bigint` | FK → `ref.pdl_relationship_catalyst.id`. **Nullable.** Same — Parent Subsidiary Details extension only. |
| `dataset_version` | `text` | PDL `$.dataset_version` of the carrying enrichment response. Captures which response asserted this edge — used for refresh diffing. |
| `timestamp_created` | `timestamptz` | `DEFAULT now()`. |
| `timestamp_modified` | `timestamptz` | `DEFAULT now()`. |

**PK**: composite on `(subject_company_id, affiliated_company_id, relationship_id)`.

**Indexes**: PK + btree on `affiliated_company_id` (reverse-lookup) + btree on `relationship_id` (filter by type).

**Why named `subject_company_id` not `company_id`**: when both FKs point at the same table, a directional name disambiguates ("who asserted this relationship" vs "the other side").

**`display_name` from `affiliated_entities[]` is NOT stored on the junction** — it's already on `integration.company.name` (set by the stub-insert if the affiliated company isn't otherwise known).

**Sole source**: `affiliated_entities[]`. Other PDL hierarchy fields are redundant projections (see §5.2 "fields explicitly dropped").

### 4.3 `ref.pdl_relationship` (V28 — new ref table)

The 4 PDL relationship-type values, loader-discovered per [ADR-0011](../decisions/0011-loader-discovered-ref-tables.md).

| Column | Type | Notes |
|---|---|---|
| `id` * | `bigint` | PK. dbt-computed via `ROW_NUMBER() OVER (ORDER BY relationship)`. |
| `relationship` * | `text` | UNIQUE NOT NULL. Canonical value. |
| `timestamp_created` | `timestamptz` | `DEFAULT now()`. |
| `timestamp_modified` | `timestamptz` | `DEFAULT now()`. |

**Loaded by**: `processing/dbt/models/ref/pdl_relationship.sql` — `SELECT DISTINCT (e.elem->>'relationship') FROM staging.pdl_api_company_parsed c, jsonb_array_elements(c.affiliated_entities) AS e(elem)`.

**Observed values** (every element seen in enrichment responses falls into these four, matching PDL's canonical Relationship Types):
- `direct_subsidiary`
- `indirect_subsidiary`
- `immediate_parent`
- `ultimate_parent`

New values appear automatically on next rebuild if PDL ever emits them. No drift detection needed (see [ADR-0011](../decisions/0011-loader-discovered-ref-tables.md)).

### 4.4 `ref.pdl_relationship_status` + `ref.pdl_relationship_catalyst` (reserved — NOT created in V28)

The `company_affiliation.status_id` / `catalyst_id` FKs are reserved as nullable columns for a future Parent Subsidiary Details extension to our PDL contract. The ref tables themselves are NOT created in V28 — they'd be created in a later migration when (and if) PDL starts emitting the values. Same loader-discovered pattern as `ref.pdl_relationship`.

### 4.5 Place tables

Defined in [doc 12](12_location.md). For reference: `ref.country`, `ref.state_province`, `ref.city`, `ref.metro`, `ref.continent`, `ref.location`.

---

## 5. Column-Level PDL → Schema Mapping

Three source paths feed `integration.company`. All three flow through one single-pass dbt SELECT that LEFT JOINs the three sources to a union-derived anchor of all `pdl_company_id`s. Source-precedence rule + stub-insert pattern are in §6.3 + §6.4 below; the merge SQL lives in `processing/dbt/models/integration/company.sql`.

### 5.1 From `person.experience[].company` (always populated)

`integration/company.sql` reads `staging.pdl_person_experience_unique` and resolves location via [doc 12 §6](12_location.md).

| PDL field | Destination |
|---|---|
| `id` | `integration.company.pdl_company_id` |
| `name` | `integration.company.name` (COALESCE fallback) |
| `size`, `founded`, `type`, `website`, `linkedin_id`, `linkedin_url`, `facebook_url`, `twitter_url`, `ticker` | Corresponding scalars (COALESCE fallback) |
| `industry` | Resolved to `ref.industry.id` → `industry_id` (COALESCE with enrichment) |
| `industry_v2` | Resolved to `ref.industry_v2.id` → `industry_v2_id`. **Sole source** — PDL Enrichment doesn't emit `industry_v2`. |
| `location.*` | Resolved through [doc 12 §6](12_location.md) → `location_id` + inline scalars. COALESCE with enrichment. |
| `raw[]` | **Not persisted.** Per-experience free text (person's own typed employer name); belongs to person.experience, not company-level. |

### 5.2 From PDL Company Enrichment (the enriched subset)

`integration/company.sql` LEFT JOINs to `staging.pdl_api_company_parsed` on `pdl_company_id`. When matched, the row's `source` becomes `'enrichment'` and shared columns take enrichment values via COALESCE.

| PDL field (Enrichment) | Destination |
|---|---|
| `id`, `name`, `size`, `founded`, `industry`, `type`, `website`, `linkedin_id`, `linkedin_url`, `facebook_url`, `twitter_url`, `ticker` | Same columns as §5.1 — enrichment wins via COALESCE |
| `display_name`, `linkedin_slug`, `mic_exchange`, `summary`, `headline`, `employee_count`, `inferred_revenue`, `total_funding_raised`, `latest_funding_stage`, `last_funding_date`, `number_funding_rounds`, `dataset_version`, `likelihood` | Corresponding enrichment-only scalars |
| `immediate_parent` (text scalar) | `immediate_parent_id` (self-FK, resolved via LEFT JOIN). **Text pdl_company_id, not a nested object.** Populated for a minority of enriched companies. |
| `ultimate_parent` (text scalar) | `ultimate_parent_id` (same shape) |
| `location.*` (10-field object) | Same resolution chain as §5.1 — location_id + inline scalars |
| `naics[]` (rich objects) | `naics_codes` jsonb — store the full element shape |
| `sic[]` (rich objects) | `sic_codes` jsonb — same |
| `tags[]`, `alternative_names[]`, `alternative_domains[]`, `funding_stages[]` | Corresponding jsonb columns |
| `employee_count_by_country` (object) | `employee_count_by_country` jsonb |
| `profiles[]` | `profiles` jsonb — multi-platform URLs (LinkedIn + Twitter + Facebook + Crunchbase) |
| `affiliated_entities[]` | One row per element in `integration.company_affiliation` — see §4.2 and §6 |

**PDL fields explicitly dropped** (redundant or non-data):

| Field | Why dropped |
|---|---|
| `affiliated_profiles[]` | Subset of `affiliated_entities[].affiliated_id` without relationship label. Counts can lag between PDL pipelines — treat `affiliated_entities` as canonical. |
| `direct_subsidiaries[]`, `all_subsidiaries[]` | Subset filters of `affiliated_entities` WHERE relationship matches. Derivable. |
| `status` (top-level field) | HTTP response code echo (always "200" for matched responses); not data |
| `metadata` | Echo of the caller's `passthrough_params`; operational, not data |
| `ultimate_parent_mic_exchange`, `ultimate_parent_ticker` | Derivable via JOIN to `ultimate_parent_id` → `integration.company.mic_exchange` / `.ticker` |

### 5.3 From `affiliated_entities[]` (stub-row source)

When an `affiliated_entities[].affiliated_id` doesn't resolve to a row produced by §5.1 or §5.2, the dbt model inserts a stub row in `integration.company`. See §6.4 for mechanics.

| PDL field | Destination |
|---|---|
| `affiliated_entities[].affiliated_id` | `integration.company.pdl_company_id` |
| `affiliated_entities[].display_name` | `integration.company.name` |
| (computed) | `integration.company.source = 'affiliation_stub'` |
| (everything else) | NULL — stub has no other data |

---

## 6. Relationship Model Design

This section records the design rationale for PDL's company-relationship data, aligned with project conventions (bigint surrogate PKs, loader-discovered ref tables, single-pass dbt rebuild).

### 6.1 Two semantics to get right

1. **Direction is stated from the subject's POV, and flips for parent vs child.**
   - `direct_subsidiary` / `indirect_subsidiary` → affiliated company is **below** the subject (subject is the parent).
   - `immediate_parent` / `ultimate_parent` → affiliated company is **above** the subject (subject is the child).

2. **Direct vs transitive (closure) edges.**
   - Tree edges: `immediate_parent`, `direct_subsidiary`.
   - Closure edges (multi-layer ancestor/descendant): `ultimate_parent`, `indirect_subsidiary`.
   - Only direct edges form the ownership tree. PDL's closure edges are preserved as given — coverage has gaps, and recomputed closure may not equal PDL's closure.

### 6.2 Single source — `affiliated_entities[]`

Every other PDL relationship field is a projection of `affiliated_entities[]` and should NOT be stored separately:

| PDL field | Derivable from `affiliated_entities` by |
|---|---|
| `affiliated_profiles` | set of all `affiliated_id` |
| `direct_subsidiaries` | `relationship = 'direct_subsidiary'` |
| `all_subsidiaries` | `relationship IN ('direct_subsidiary', 'indirect_subsidiary')` |
| `immediate_parent` (scalar) | `relationship = 'immediate_parent'` |
| `ultimate_parent` (scalar) | `relationship = 'ultimate_parent'` |

The two `ultimate_parent_*` market-identity fields (`ultimate_parent_ticker`, `ultimate_parent_mic_exchange`) are attributes of the parent company, not relationship data. Read via JOIN from the parent's own `integration.company` row.

**Exception by design choice**: we keep `integration.company.immediate_parent_id` and `ultimate_parent_id` as denormalized scalar FKs (few populated rows; trivial cost; saves a JOIN on common queries). See §3 commentary.

### 6.3 Source-precedence rule (3-value enum)

`integration.company.source` is computed at SELECT time via:

```
CASE
  WHEN enr.pdl_company_id IS NOT NULL THEN 'enrichment'
  WHEN pe.pdl_company_id  IS NOT NULL THEN 'person_experience'
  ELSE 'affiliation_stub'
END
```

Highest-fidelity tier wins. Enrichment ⊆ person.experience (every enriched `pdl_company_id` is also in person.experience), so the only way to land at `affiliation_stub` is to be referenced as someone's `affiliated_entities[].affiliated_id` without appearing anywhere else.

**Transitions across rebuilds.** Stateless rebuild + this CASE handles all transitions automatically. A stub gets promoted to `'person_experience'` or `'enrichment'` on the next rebuild if upstream data changes; an enriched row stays enriched as long as the enrichment response is still in staging.

### 6.4 Stub-insert pattern

When `affiliated_entities[].affiliated_id` points at a `pdl_company_id` that has no row from person.experience or enrichment, we insert a **stub** row in `integration.company`:

| Column | Stub value |
|---|---|
| `pdl_company_id` | `affiliated_entities[].affiliated_id` |
| `name` | `affiliated_entities[].display_name` |
| `source` | `'affiliation_stub'` |
| (everything else) | NULL |

**Why stubs (vs INNER-JOIN orphan drop):**

- Junction INNER JOINs always resolve — no silent data loss. A large company's enrichment response can list dozens of affiliated entities, most of which never appear in our person.experience set; orphan-drop would lose most of that graph. Unacceptable.
- Graph traversal works immediately. Walking `company_affiliation` from a parent (say, Acme Holdings) to an indirect subsidiary (Acme Games) doesn't dead-end at "company not found."
- Stubs are first-class match candidates when richer data later arrives (next enrichment cycle).
- Cost is trivial — stub rows carry only 2 meaningful columns; jsonb cols are NULL.

**Earliest-parent display_name tiebreak.** A single `affiliated_id` may appear in multiple enriched companies' `affiliated_entities[]` with slightly different `display_name` strings (e.g., `"Acme"` vs `"Acme, Inc."` vs `"Acme.com"`). The dbt model picks the display_name from the parent with the lowest `pdl_company_id` (deterministic stable ordering). See `processing/dbt/models/integration/company.sql` for the query shape.

**Stubs are ephemeral.** A stub exists only as long as some currently-staged enrichment response references it in `affiliated_entities[]`. If a parent gets re-enriched and the affiliated_id drops from its list, the stub disappears on the next rebuild. No accumulation. This is correct stateless-rebuild behavior — we don't keep ghost rows.

---

## 7. Edge Cases / Known Data Quirks

1. **`affiliated_profiles[]` count may not equal `affiliated_entities[]` count.** They come from related-but-separate PDL pipelines; one can lag the other. Treat `affiliated_entities` as canonical.
2. **`status` / `catalyst` frequently absent on affiliated entities.** Not in the PDL bundle this pipeline uses; columns are reserved as nullable for future Parent Subsidiary Details extension.
3. **`industry_v2` absent from Enrichment responses.** Verified against enrichment responses — Enrichment never emits `industry_v2`. `integration.company.industry_v2_id` populates only from person.experience.
4. **`immediate_parent` / `ultimate_parent` are text scalars, not nested objects.** PDL emits as `response_json->>'immediate_parent'` (string `pdl_company_id`). Initial spec assumed nested objects — corrected.
5. **`metadata` may not be present** on all enrichment responses. Don't gate logic on its presence.
6. **NULL `industry` from enrichment.** COALESCE handles fallback to person.experience.company.industry; FK resolves to NULL if both sources are NULL.
7. **PDL 404 responses (company not matched).** Filter out at staging (`response_status = 200`).
8. **Recomputed closure may not equal PDL's closure** because of coverage gaps. PDL may assert `indirect_subsidiary` (closure) for Acme Holdings → Acme Games without providing the intermediate Acme Media → Acme Games direct edge. Keep PDL's closure edges as given; don't try to recompute them.

---

## 8. Open Questions / Decisions to Confirm

1. **Target database**: PostgreSQL 18 (local Docker Compose). Confirmed.
2. **Country reference shape**: PDL string as FK key, ISO codes advisory. Settled in [doc 12](12_location.md).
3. **Stateful company-ID ledger**: Not needed — `pdl_company_id` is sufficient. A future `catalog.company_key_map` mirroring `catalog.person_key_map` becomes the right pattern if cross-source company resolution is ever needed (e.g. LEI / D-U-N-S). Deferred until a real second source demands it.
4. **Re-enrichment**: run on demand; the architecture supports it without change. [doc 18 §Running the callers](../design/18_pdl_api_generic_caller.md#running-the-callers--pipeline-decoupling) covers how to run it.

---

## 9. What's Deferred

V28 lands: 8 jsonb columns, `integration.company_affiliation`, `ref.pdl_relationship`, stub-insert pattern, 3-value `source` enum. What remains:

**PDL Parent Subsidiary Details extension bundle.** Adds `status` / `catalyst` / `start_date` / `end_date` / `citations` to each `affiliated_entities[]` element. The bundle this pipeline uses doesn't include it. Additive when it lands — `company_affiliation` gains 3-4 nullable columns; `ref.pdl_relationship_status` + `ref.pdl_relationship_catalyst` get created (loader-discovered, same pattern as `ref.pdl_relationship`).

**`ownership_edge` canonical layer.** A derived table with `(parent_id, child_id, edge_kind)` where `edge_kind ∈ {'direct', 'closure'}`. Forces every edge into one canonical direction (always parent→child) and collapses reciprocal duplicates. Cleaner for tree traversal queries than the raw junction. Defer until a consumer needs it — junction-based queries with CASE on `relationship_id` cover current needs.

**Re-enrichment cycle.** When enriched data ages, re-enrichment refreshes the set. The architecture supports it — reset the affected queue rows to `pending`, run an enrichment pass (new audit rows land in `pdl_api.company_enrichment_call`), then rebuild with dbt. Not implemented as a job. See [doc 18 — Running the callers + pipeline decoupling](../design/18_pdl_api_generic_caller.md#running-the-callers--pipeline-decoupling).

**Stable internal company IDs.** Future stable-id layer for companies (analogous to `catalog.person_key_map`). Not needed yet.

**Cross-source company merge.** PDL is the only company source. If another source is added, the LEFT JOIN + COALESCE pattern extends naturally (add a fourth staging source), with identity resolution via the future `catalog.company_key_map` ledger.

**Re-evaluation triggers** (reopen this section if any change):
- PDL bundle eligibility changes (we get more fields in `affiliated_entities`)
- Consumer query patterns demand promoting a jsonb column to a separate junction with `ref.*` for canonical-value search
- A second company source arrives (e.g. LEI registry, manual entry)
- Re-enrichment cycle becomes operationally necessary
