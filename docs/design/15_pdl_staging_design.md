# PDL Person Staging Design

**Status:** Implemented. This is the design record for the PDL Person staging tier.
**Scope:** PDL **person** staging (`raw.pdl_person` → `staging.pdl_person_*_parsed` → `staging.pdl_person_*_unique` → `integration.*`). The companion pipeline for PDL API company enrichment (`pdl_api.*` → `staging.pdl_api_company_parsed` → `integration.company` merge) is documented in [`18_pdl_api_generic_caller.md`](18_pdl_api_generic_caller.md).

This document captures the design decisions for PDL person staging. It is the entry point when reading about the PDL person staging tables (person, experience, education, companies, schools, addresses) and the unique-tier dedup tables that feed integration dbt models.

Source-agnostic dbt layer mechanics (raw → staging → ref → integration, DAG ordering, naming conventions, refresh patterns) live in [`16_dbt_pipeline_layers.md`](16_dbt_pipeline_layers.md). This doc covers the PDL-person-specific decisions on top.

**Companion docs:**
- [`18_pdl_api_generic_caller.md`](18_pdl_api_generic_caller.md) — PDL API company enrichment + cleaners (own staging tier `staging.pdl_api_company_parsed`)
- [`16_dbt_pipeline_layers.md`](16_dbt_pipeline_layers.md) — the layer model
- [`../requirements/01_pipeline_requirements.md`](../requirements/01_pipeline_requirements.md) §2 — refresh patterns per layer (stateless vs stateful)
- [`../decisions/0005-ref-population-layer.md`](../decisions/0005-ref-population-layer.md) — ref tables are populated by their own dedicated dbt layer (`models/ref/`), not by staging
- [`../data_model/13_person.md`](../data_model/13_person.md) §6 — PDL person field inventory and column-mapping intent
- `modeling/dbml/staging.dbml` — destination shape (source of truth)

---

## Decided

### 1. Selective normalization at staging — driven by what integration needs

Not every nested object inside the PDL JSON gets its own staging table. The rule:

> Break out a nested object into its own staging table if **either**:
> 1. Integration consumes it as its own table (1:1 mapping to an `integration.*` entity), **or**
> 2. It's a multi-path UNION (the same nested shape appears at multiple JSON paths) whose dedup'd output is consumed by more than one integration / ref table.
>
> Otherwise it stays as `jsonb` on the parent staging table.

Criterion 1 covers person / experience / education / company / school. Criterion 2 is what justifies `pdl_person_addresses_parsed` even though there is no `integration.address` table — addresses appear at 3 JSON paths and the dedup'd unique tier feeds `ref.location` plus inline scalars on `integration.person` + `integration.company` plus `integration.experience_location.location_id` + `integration.school.location_id`. Materializing the UNION once at staging avoids re-flattening the JSON three ways downstream.

PDL person JSON has multiple nesting levels:

```
person
├── experience[]                  (array of sub-objects)
│   ├── company                   (nested object)
│   │   └── location              (nested object)
│   └── title                     (nested object)
│       └── levels[]              (text array)
├── education[]                   (array of sub-objects)
│   └── school                    (nested object)
│       └── location              (nested object)
└── profiles[]                    (array of sub-objects)
```

Decisions per level:

| Level | Object | Own staging table? | Why |
|---|---|---|---|
| 0 | person scalars | Yes — `pdl_person_parsed` | One row per raw record |
| 1 | experience[], education[] | Yes — `pdl_person_experience_parsed`, `pdl_person_education_parsed` | Criterion 1 — each is an array of sub-objects integration consumes as its own table (`integration.experience`, `integration.person_education`). |
| 1 | profiles[] | **No** | `profile_id` is always NULL in the deliveries profiled, so profiles have no usable dedup key. Top-level social scalars on `pdl_person_parsed` cover the relevant networks. |
| 2 | company (inside experience) | **Yes** — `pdl_person_companies_parsed` | Integration has `integration.company` as its own table |
| 2 | school (inside education) | **Yes** — `pdl_person_schools_parsed` | Integration has `integration.school` as its own table |
| 2 | title (inside experience) | **No** — stays inline on `pdl_person_experience_parsed` as `title_name`, `title_role`, `title_sub_role`, `title_class` scalars | No integration table called "title"; the 3 classification columns feed `ref.job_title_class` / `ref.job_title_role` / `ref.job_title_subrole` independently (3 individual FKs from `integration.experience`, no composite ref table). |
| 3 | location (inside company / school / top-level person) | **Yes** — `pdl_person_addresses_parsed` | Criterion 2 — 3-path UNION feeds `ref.location` + inline scalars on `integration.person` & `integration.company` + `experience_location.location_id` + `school.location_id`. No `integration.address` table (address scalars are inlined on the entity tables). |
| Any depth | classification text arrays (skills, interests, title.levels, degrees, majors, minors, name_aliases, location_names, countries, regions) | **No** — stay as `jsonb` columns on the parent staging table | Per the staging.dbml header convention: ref dbt models unnest at consume time via `jsonb_array_elements_text()` and populate ref directly from staging. No separate staging table earns its keep for a tiny text array. |

### 2. Full PDL person staging surface — the table list

**Parsed tier (6 tables):**

| Table | Source path | Cardinality |
|---|---|---|
| `pdl_person_parsed` | `raw.pdl_person` top-level scalars | 1:1 with raw |
| `pdl_person_experience_parsed` | `$.experience[*]` unnest | several rows per person (largest staging table) |
| `pdl_person_education_parsed` | `$.education[*]` unnest | a few rows per person |
| `pdl_person_companies_parsed` | `$.experience[*].company` flatten | ≤ experience cardinality |
| `pdl_person_schools_parsed` | `$.education[*].school` flatten | ≤ education cardinality |
| `pdl_person_addresses_parsed` | 3 paths UNION'd — see decision #3 below | — |

**Unique tier (6 tables):** one `_unique` per `_parsed` table; natural keys are listed under [Natural keys](#natural-keys-for-_unique-tables) below. `pdl_person_unique` resolves merged ids via `catalog.pdl_id_aliases`.

**Staged tier:** not authored for PDL — see [`_staged` tier](#_staged-tier--skipped-for-pdl) below. Integration dbt models consume `_unique` directly.

### 3. Address pattern — single table, 3 source paths UNION'd

Addresses appear at **3 locations** inside a PDL person payload — UNION'd into one `pdl_person_addresses_parsed` table with a `source_context` column distinguishing rows:

| `source_context` | JSON path | What PDL actually emits (from profiling a delivery) |
|---|---|---|
| `'person_home'` | `$.location_*` (top-level scalars) | `name`, `locality`, `region`, `country`, `metro`, `continent`, `postal_code`, `geo`: real strings. **`street_address` + `address_line_2`: bool placeholders (`"false"` / `"true"`) — never real addresses.** Hardcode NULL in branch SQL. |
| `'experience_company_hq'` | `$.experience[*].company.location.*` (nested) | All 10 location fields populated where PDL has data (`street_address` is present on a large share of rows). |
| `'education_school'` | `$.education[*].school.location.*` (nested) | **Coarse-grain only**: `name`, `locality`, `region`, `country`, `continent` populated. `metro`, `street_address`, `address_line_2`, `postal_code`, `geo` always NULL (PDL doesn't emit street-level for schools). |

UNION ALL contract: all 3 branches output the same 10-column shape. Each branch leaves the irrelevant columns NULL.

**Why no 4th `'job_company_hq'` branch** (the path on `$.job_company_location_*`): it duplicates the `is_primary=true` experience entry's company location. PDL ships the current job's company HQ both at the top level (`$.job_company_location_*`) AND inside the experience array. Including both would double-count. Integration models that need "the current job's HQ" pick the `is_primary=true` row from `experience_company_hq`.

`source_idx` is the experience/education array index for nested paths; **0** for the top-level `person_home` branch (NOT NULL constraint at the `_unique` tier; sentinel 0 covers it under standard UNIQUE semantics).

**Why one table over multiple separate tables:**

- Same column shape → UNION ALL is mechanical; multiple tables would duplicate the column list everywhere.
- One model file is cheaper to maintain.
- `source_context` preserves provenance for later integration JOINs.
- Companies and schools don't have the same problem (each has only one source path) — this is an addresses-only decision.

**`source_context` at `_unique`:** preserved by construction. The natural key `(person_pdl_id, source_context, source_idx)` IS the entry's identity in the source PDL record. See [Address-specific](#address-specific-source_context-preserved-at-_unique) below.

**Empirical findings driving this design:** profiling of real PDL deliveries established the bool-placeholder pattern, the coarse-grain school location pattern, and the job_company_hq duplication.

### 4. Title sub-object is flattened, not broken out

PDL title is `{name, role, sub_role, class, levels[]}`. The scalars become flat columns on `pdl_person_experience_parsed` (`title_name`, `title_role`, `title_sub_role`, `title_class`). The `levels[]` text array stays as a jsonb column.

This is consistent with #1 (no integration table called "title") and with the convention that classification text arrays stay as jsonb at staging. The 3 staging columns (`title_class`, `title_role`, `title_sub_role`) feed `ref.job_title_class` / `ref.job_title_role` / `ref.job_title_subrole` via dedicated ref dbt models; `integration.experience` JOINs to each independently for FK resolution. Three individual FKs (rather than one composite classification ref) preserve PDL's partial classifications — e.g. a role with no sub_role. Same pattern for `title.levels[]` → `ref.seniority_level`.

### 5. All parsed models read raw directly as siblings (not chained)

Mechanically: `pdl_person_parsed`, `pdl_person_experience_parsed`, `pdl_person_education_parsed`, `pdl_person_companies_parsed`, `pdl_person_schools_parsed`, `pdl_person_addresses_parsed` all read `source('raw', 'pdl_person').payload` directly. Each does its own JSON_TABLE flatten on its own JSON path.

**Why siblings, not parent-children off `pdl_person_parsed`:**

- `pdl_person_parsed` does not retain `experience[]` / `education[]` / `profiles[]` arrays — they are flattened to siblings, not stored as raw jsonb on the parent. A sibling that depended on the parent couldn't see the array data.
- Siblings parallelize cleanly under `dbt --threads 4`. Wall-clock = slowest single sibling, not sum-of-siblings.
- Alternative (fat parent with `experience_raw jsonb`, `education_raw jsonb`, `profiles_raw jsonb` columns) would (a) duplicate storage — same arrays stored once flattened, once raw, (b) serialize work that's naturally parallel, (c) bloat the parent column list, making `on_schema_change='fail'` painful.

**Cost we pay:** each sibling scans `raw.pdl_person.payload` independently. 6 sibling scans over a multi-million-row raw table would normally mean 6× I/O. In practice the Postgres buffer cache absorbs subsequent scans after the first; CPU-bound JSON parsing dominates wall-clock, and the parallelism gain dwarfs the cache-hit cost.

**Parallel cap is `--threads` in dbt, not "all siblings at once":** with `--threads 4`, dbt runs up to 4 sibling models at a time. The other 2 queue and start as the first 4 finish. Extra siblings extend wall-clock by extending the queue, not by increasing peak concurrency.

### 6. dbt DAG ordering and layer boundaries

See [`16_dbt_pipeline_layers.md`](16_dbt_pipeline_layers.md) §"DAG ordering" — dbt has no layer barriers; per-model deps via `{{ ref() }}` drive the topological sort.

For PDL specifically: integration models won't start until their specific staging upstream finishes, and ref models won't start until their specific staging upstream finishes. The "layer" terminology used throughout this doc is a useful mental shorthand, not an enforcement boundary.

### 7. Refresh patterns and the staging↔ref boundary

See [`../requirements/01_pipeline_requirements.md`](../requirements/01_pipeline_requirements.md) §2 for the layer refresh patterns table, and [`../decisions/0005-ref-population-layer.md`](../decisions/0005-ref-population-layer.md) for the rationale behind ref being populated by a dedicated ref layer (not by staging).

Net effect for PDL staging: every staging dbt model is a TRUNCATE+INSERT rebuild. Catalog ledger reads happen at `_unique` (alias resolution) only — `_staged` is skipped for PDL (see below). Integration dbt models read from `_unique` directly. Ref tables are populated by their own ref dbt models in `models/ref/` — staging models never INSERT into ref.

---

## Resolved decisions

### Dedup ordering rule

Uniform rule across every `_unique` model: `ORDER BY loaded_at DESC, partition_id DESC` (latest load wins). Same rule everywhere; perf tuning deferred. Revisit when generic `unique()` tests fire repeatedly with content-divergent duplicates.

### Natural keys for `_unique` tables

| `_unique` table | Natural key |
|---|---|
| `pdl_person_unique` | `pdl_id` (alias-resolved via `catalog.pdl_id_aliases`) |
| `pdl_person_companies_unique` | `company_pdl_id` |
| `pdl_person_schools_unique` | `school_pdl_id` |
| `pdl_person_experience_unique` | `(person_pdl_id, company_pdl_id, start_year, title_name)` |
| `pdl_person_education_unique` | `(person_pdl_id, school_pdl_id, start_year, degrees::text)` |
| `pdl_person_addresses_unique` | `(person_pdl_id, source_context, source_idx)` |

The 4-column keys for experience and education add discriminator columns (`title_name`, `degrees::text`) to preserve legitimately-distinct entries (promotions, dual-degree programs, multi-title roles) that a 3-column key would wrongly merge. Validated against a full delivery: the discriminator eliminated almost all experience duplicate groups and substantially reduced the education ones (remaining education near-duplicates are handled by the `education_duplicate` cleansing routine).

NULL handling: rows with any NULL in the natural-key columns survive un-deduped (each NULL is its own group in SQL). Acceptable noise.

### Alias resolution in `pdl_person_unique`

PDL re-merges pdl_ids across deliveries, so multi-hop chains (A → B in one delivery, B → C in a later one) occur in practice and a single lookup would leave stale ids. `pdl_person_unique` walks `catalog.pdl_id_aliases` with a recursive CTE to each chain's terminal id, capped at 10 hops. Two-member cycles (A → B, later B → A) are collapsed deterministically: both members map to `LEAST(A, B)`, so the pair becomes one row that is stable across rebuilds. Longer cycles are not canonicalized; the warn-level singular tests `pdl_person_unique_alias_cycle_guard` and `pdl_person_unique_alias_hop_cap` (`processing/dbt/tests/`) surface cycles and cap hits.

### Address-specific: `source_context` preserved at `_unique`

Preserved by construction — the natural key `(person_pdl_id, source_context, source_idx)` IS the entry's identity in the source PDL record, not its content. Content-based cross-context dedup is not performed at staging — consistent with the integration-layer decision to inline address scalars on the entity tables and accept formatting variance rather than enforce a cross-entity dedup invariant.

### PDL company aliases — none needed in the Person stream

Verified against `raw.project_pdl_deltas()` and the PDL Data License delivery contract ([`../requirements/01_pipeline_requirements.md`](../requirements/01_pipeline_requirements.md)): PDL's Person delivery `MERGED_RECORDS` only contains person id pairs. No company-level merges in this stream. `pdl_person_companies_unique` dedups directly on `company_pdl_id` with no alias-resolve step. Company id changes surfaced by the PDL Company Enrichment API are handled on the PDL API path ([`18_pdl_api_generic_caller.md`](18_pdl_api_generic_caller.md)).

### `_staged` tier — skipped for PDL

All PDL `_unique` tables feed integration directly; no `_staged` tier is authored for PDL. Reasons:

- Inactive PDL persons aren't in the current `data/` files → not in `_parsed` → not in `_unique`. The filter step would be a no-op.
- Reactivation-aware filter SQL is non-trivial; not worth authoring for a no-op layer.
- `_staged` stays in the naming convention as a **per-source optional** tier (see the `modeling/dbml/staging.dbml` header) so a future source with genuine inactive-filter logic can use it.
- Reversible: if PDL ever ships inactive persons in `data/`, adding `_staged` models is a small, self-contained change.

---

## Forward-looking considerations

PDL is the only source. The staging design keeps the door open for another source without committing to one:

- **Per-source staging tiers.** Any additional source would get its own `raw.<source>_*` and `staging.<source>_*` (parsed/unique/optional staged) tables, running independently of PDL. The DAG would fan out per source at raw → staging and re-converge at integration.
- **Ref population across sources.** Each ref dbt model would UNION the relevant staging tables (stateless rebuild still applies, per ADR-0005). Each ref model has only the PDL branch.
- **Cross-source resolution belongs in integration.** Staging stays "data as the source emits it"; any precedence or identity resolution would live in integration dbt models, where source-attribution columns (e.g. `integration.company.source`) already exist.

---

## References

- [`16_dbt_pipeline_layers.md`](16_dbt_pipeline_layers.md) — source-agnostic dbt layer mechanics
- [`02_pipeline_design.md`](02_pipeline_design.md) — staging layer responsibilities (canonical)
- [`../requirements/01_pipeline_requirements.md`](../requirements/01_pipeline_requirements.md) §2 — refresh patterns per layer
- [`../data_model/13_person.md`](../data_model/13_person.md) §6 — PDL person field inventory
- [`../decisions/0001-dbml-owns-table-shape-across-layers.md`](../decisions/0001-dbml-owns-table-shape-across-layers.md)
- [`../decisions/0002-fk-enforcement-at-integration-only.md`](../decisions/0002-fk-enforcement-at-integration-only.md)
- [`../decisions/0003-staging-bulk-load-pattern-1.md`](../decisions/0003-staging-bulk-load-pattern-1.md)
- [`../decisions/0004-integration-constraint-pattern-2.md`](../decisions/0004-integration-constraint-pattern-2.md)
- [`../decisions/0005-ref-population-layer.md`](../decisions/0005-ref-population-layer.md)
- `modeling/dbml/staging.dbml` — destination shape
- `processing/dbt/dbt_project.yml` — materialization config
