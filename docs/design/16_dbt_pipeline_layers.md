# dbt Pipeline Layers — Mechanics and Conventions

**Scope:** Source-agnostic. Applies to PDL Person, the PDL API tier, and any source added later.

This document describes the dbt layer model used across the pipeline: what each layer is for, who populates it, how the layers connect, and what the DAG looks like under `dbt build`. Source-specific design lives in dedicated docs (e.g. [`15_pdl_staging_design.md`](15_pdl_staging_design.md) for PDL person, [`18_pdl_api_generic_caller.md`](18_pdl_api_generic_caller.md) for the PDL API tier).

**Companion docs:**
- [`../requirements/01_pipeline_requirements.md`](../requirements/01_pipeline_requirements.md) §2 — refresh patterns per layer (the architectural baseline)
- [`02_pipeline_design.md`](02_pipeline_design.md) — staging layer responsibilities
- [`../decisions/0001-dbml-owns-table-shape-across-layers.md`](../decisions/0001-dbml-owns-table-shape-across-layers.md) — DBML is the contract
- [`../decisions/0005-ref-population-layer.md`](../decisions/0005-ref-population-layer.md) — ref is populated by a dedicated ref dbt layer (`models/ref/`), not by staging or integration

---

## The layers

```
┌─────────────────────────────────────────────────────────────┐
│ catalog (ledger + load audit)  ← stateful append-only       │
└─────────────────────────────────────────────────────────────┘
                ▲
                │ alias resolve
                │
┌────────────┐  ┌────────────────────────┐  ┌──────────────┐
│   raw.*    │─▶│  staging.*             │─▶│ integration. │
│            │  │   parsed → unique →    │  │   *          │
│ ingester   │  │   (staged, optional)   │  │              │
└────────────┘  └────────────────────────┘  └──────────────┘
                            │                      ▲
                            ▼                      │ FK JOINs
                     ┌──────────────┐              │
                     │   ref.*      │──────────────┘
                     └──────────────┘
                     populated by dedicated
                     ref dbt models (models/ref/),
                     reading staging
```

### `raw.*`

Lands ingested source data as faithfully as possible (`JSONB` payloads for JSON sources; tabular columns for CSV sources). Populated by the ingester (`processing/s3_ingester/`), not dbt. Owned by Flyway for DDL.

**Refresh:** stateless rebuild — `TRUNCATE` + `COPY` per delivery file (into the file's leaf partition).

### `staging.*` — three sub-tiers

| Sub-tier | Suffix | Purpose | Catalog reads | Ref interaction |
|---|---|---|---|---|
| Parsed | `_parsed` | Faithful flatten of raw JSON/CSV to typed columns. `JSON_TABLE` for nested arrays. No dedup. | None | None |
| Unique | `_unique` | Dedup by natural key. Alias-resolve via catalog ledger (PDL ID aliases, etc.) | Yes (alias resolution) | None |
| Staged | `_staged` | **Per-source optional.** Inactive-filter via catalog ledger. Not authored for PDL (see [15](15_pdl_staging_design.md)). | Yes (inactive filter) | None |

Naming: `staging.<source>_<entity>_<sub-tier>`. Examples: `staging.pdl_person_parsed`, `staging.pdl_person_unique`, `staging.pdl_api_company_parsed`.

**Refresh:** stateless rebuild — `TRUNCATE` + `INSERT` per dbt run, every sub-tier.

**Populated by:** dbt models in `processing/dbt/models/staging/<source>/` (`pdl_person/`, `pdl_api/`).

**Bulk-load pattern (Pattern 1):** indexes dropped pre-INSERT and recreated post-INSERT. See ADR-0003.

### `integration.*`

Conformed entities with FKs — the data model consumers query. Each integration entity reads the source's final staging tier (`_unique` for PDL), which has already resolved PDL id aliases against the catalog ledger. Source-attribution columns (e.g. `integration.company.source`, `integration.experience_industry.source`) record where a row came from, so another source could be UNION'd in later.

**Refresh:** stateless rebuild — `TRUNCATE` + `INSERT` per dbt run.

**Populated by:** dbt models in `processing/dbt/models/integration/`.

**FK enforcement:** FKs exist on `integration.*` and `ref.*` only, never on raw or staging (ADR-0002). They are dropped at `on-run-start` and recreated `NOT VALID` at `on-run-end`; dbt `relationships` tests are the row-level check (ADR-0009).

### `ref.*`

Controlled vocabularies (`ref.skill`, `ref.interest`, `ref.job_title_class` / `_role` / `_subrole`, `ref.seniority_level`, `ref.industry`, `ref.country`, `ref.location`, etc.). Each entry has a surrogate ID; integration tables FK to these IDs.

**Refresh:** stateless rebuild — `TRUNCATE` + `INSERT DISTINCT` per dbt run. Surrogate IDs are dbt-computed (`ROW_NUMBER() OVER (ORDER BY <natural_key>)`, ADR-0008) and are not stable across rebuilds.

**Populated by:** dedicated ref dbt models in `processing/dbt/models/ref/` (NOT `models/staging/`, NOT `models/integration/`). Each ref table has its own `.sql` model that reads from staging and emits DISTINCT vocab. Integration dbt models then JOIN to ref tables for FK resolution. See ADR-0005 for the rationale.

### `catalog.*` — ledger + audit

Two distinct families of stateful tables:

**Identity ledger** — `pdl_id_aliases`, `pdl_inactive`, `person_key_map`, `merge_events`. Append-only, cumulative across deliveries. Records identity events (PDL merges and deactivations; `person_key_map` and the manual-merge event type are reserved and unused).

**Load audit** — `pipeline_run`, `ingestion_run`, `ingestion_file`, `pdl_delivery` (plus `_dropped_fks`, the ADR-0009 hook bookkeeping). Append-only, cumulative. Records which deliveries and files were loaded, which is what makes the ingester idempotent per delivery. See [`02_pipeline_design.md` §10 Catalog logging](02_pipeline_design.md#10-catalog-logging).

**Refresh:** stateful append-only. The only subsystem (besides the PDL API call tables, below) that breaks stateless rebuild.

**Populated by:** the ingester (audit) and the `raw.project_pdl_deltas()` projection function (identity ledger), not dbt.

### `pdl_api.*` — API queue + call audit

Queue tables (`*_input_list`) and per-call response tables (`company_enrichment_call`, `company_cleaner_call`, `location_cleaner_call`, `school_cleaner_call`) written by `processing/pdl_api`. Stateful (responses are cached so the API is not re-called on every rebuild). dbt reads them into `staging.pdl_api_company_parsed`. See [18](18_pdl_api_generic_caller.md).

---

## Naming convention

```
staging.<source>_<entity>_<sub-tier>
```

- `<source>` — `pdl_person`, `pdl_api_company`. Lower-snake-case.
- `<entity>` — the entity unnested or flattened, when distinct from the source root. For PDL person: `experience`, `education`, `companies` (nested), `schools` (nested), `addresses` (cross-cutting). Omit when the table is the source root.
- `<sub-tier>` — `parsed`, `unique`, `staged`.

Examples:
- `staging.pdl_person_parsed` (source root, parsed)
- `staging.pdl_person_experience_parsed` (sub-entity, parsed)
- `staging.pdl_person_unique` (source root, unique)
- `staging.pdl_person_addresses_parsed` (cross-cutting sub-entity, parsed)

Integration tables use bare entity naming: `integration.person`, `integration.experience`, `integration.person_education`, `integration.company`, `integration.company_affiliation`, `integration.school`, plus `integration.person_*` junctions (skill, interest, language, country, state_province, location) and `integration.experience_*` junctions (location, industry, seniority_level). DBML source: `modeling/dbml/integration.dbml`. There is no `_conformed` suffix (ADR-0007) and no `integration.address` table — address scalars are inlined on `integration.person` + `integration.company`.

Ref tables are flat-named: `ref.<table>` (no source prefix). `ref.skill`, not `ref.pdl_skill` — the vocabulary is source-neutral, so another source could feed the same table.

---

## Materialization conventions

All staging / ref / integration tables follow the same dbt materialization recipe:

```yaml
+materialized: incremental
+incremental_strategy: append
+pre_hook: "TRUNCATE TABLE {{ this }} RESTART IDENTITY CASCADE"
+on_schema_change: fail
```

**Why this recipe** (per the comment in `processing/dbt/dbt_project.yml`):

- `table` materialization would `DROP+CREATE` the Flyway-owned table. Forbidden — DDL lives in Flyway.
- `merge` materialization does per-row comparison. Wasted work when most/all rows change every rebuild (which is the case under stateless rebuild).
- `incremental + append + pre_hook: TRUNCATE` = single bulk INSERT, no comparison.
- `CASCADE` handles FK ordering automatically — dbt's DAG builds parents before children, so cascade-truncate is harmless on already-empty children.
- `on_schema_change='fail'` catches drift between DBML CREATE TABLE shape and dbt model SELECT shape. Single source of truth enforcement (per ADR-0001).

Schema names are bare (`staging` / `integration` / `ref`) thanks to the `generate_schema_name` macro override at `processing/dbt/macros/overrides/generate_schema_name.sql`. Without it, dbt prepends the profile target schema (e.g., `dev_staging`).

---

## Wrapper policy

No layer uses wrappers (views / stored functions) over its tables. Callers hit tables directly:

| Layer | Rationale |
|---|---|
| `raw.*` | Raw is a landing surface — anything on top would encode source-specific parsing that belongs in staging. |
| `staging.*` | The DBML sub-tier tables ARE the API — wrapping them fragments the schema surface without simplifying anything. Every layer transition should be a dbt model, not a view. |
| `ref.*` | Ref tables are join targets; wrapping them adds a hop without simplifying anything. |
| `integration.*` | Integration is the data model consumers query — the tables are the public contract. Wrappers would obscure the actual data model and add a maintenance surface with no value. |
| `catalog.*` | These are the historical record; wrapping them abstracts away information consumers may need. |

A consumer-facing presentation layer built on top of integration (denormalized tables, search helpers) could reasonably use function wrappers where they encapsulate a semantic pattern callers could get wrong; that layer is out of scope here.

---

## DAG ordering — per-edge, not per-layer

dbt has NO explicit "wait until layer N finishes before starting layer N+1" barrier. Each model declares its upstream deps via `{{ ref('upstream_model_name') }}`. dbt builds a directed acyclic graph from those declarations and runs models in topological order.

With `dbt build --threads N`, dbt picks up to N models whose specific upstreams are all built and runs them in parallel. As models finish, more become eligible.

**Implications:**

- Models in the same "layer" can finish at different times. A small model whose upstream is fast will finish before a heavy model in the same layer.
- Downstream models start as soon as their specific upstreams finish, even if other models in the upstream layer are still running.
- A fast integration model on one DAG branch can run concurrently with a heavy parsed model on another DAG branch.

**Example run** (illustrative, not measured) on PDL person with `--threads 4`:

```
t=0      :  Multiple parsed models start in parallel up to --threads cap
            (deps = raw source only). The PDL parsed siblings are:
            ├─ pdl_person_parsed (heaviest)
            ├─ pdl_person_experience_parsed
            ├─ pdl_person_education_parsed
            ├─ pdl_person_companies_parsed
            ├─ pdl_person_schools_parsed
            └─ pdl_person_addresses_parsed

t=~15min :  pdl_person_companies_parsed or schools_parsed may finish first
            (smaller). Their _unique counterparts become eligible, start.
            Queueing happens at the --threads cap, not at the layer boundary.

t=~20min :  pdl_person_education_parsed finishes
            → pdl_person_education_unique starts

t=~30min :  pdl_person_parsed finishes
            → pdl_person_unique starts
            → meanwhile, the smaller _unique tables may have finished
              and ref models reading them are already eligible

t=~35min :  Ref models start (small DISTINCT queries on staging data)
            → integration models whose ref + staging deps are met start
```

No layer-wide barriers — model B starts the moment its specific upstreams are done.

**Implication for capacity planning:** the `--threads` parameter caps peak concurrency, not the total number of models. Adding more siblings at the same layer extends wall-clock by extending the queue, not by spawning more concurrent work. No need to scale Postgres to N cores per N siblings.

---

## Parsed models read raw directly as siblings (general design choice)

Each parsed model reads from `source('raw', '<table>')` directly, not from another parsed model. Sibling parsed models within the same source pipeline are independent of each other.

**Why siblings, not parent→children:**

- The "root" parsed table (e.g., `pdl_person_parsed`) holds top-level scalars. It does NOT retain raw nested arrays as `jsonb` columns — those are flattened to sibling tables. A child parsed model that depended on the root would have no nested data to read from it.
- Siblings parallelize cleanly under `dbt --threads`. Wall-clock = slowest single sibling, not sum of siblings.
- Alternative (fat root with raw nested arrays + child parsed models depending on root) would duplicate storage, serialize work, and bloat the root column list.

**Cost paid:** each sibling scans `raw.<table>.payload` independently. N siblings → N scans. In practice the Postgres buffer cache absorbs subsequent scans after the first; CPU-bound JSON parsing dominates wall-clock.

This pattern is source-agnostic: any source added later would use the same shape — per-source parsed siblings reading raw directly.

---

## The staging↔ref unpack boundary

See [`../decisions/0005-ref-population-layer.md`](../decisions/0005-ref-population-layer.md).

Net rule: staging models never INSERT into ref. Simple text arrays (skills, interests, classification arrays at any depth) stay as `jsonb` columns on their parent staging table. Dedicated ref dbt models in `models/ref/` unnest at consume time via `jsonb_array_elements_text()` and emit DISTINCT vocab into ref (TRUNCATE + INSERT DISTINCT). Integration dbt models then JOIN to ref tables for FK resolution.

---

## Refresh patterns per layer — summary

The full refresh-pattern-per-layer table lives at [`../requirements/01_pipeline_requirements.md`](../requirements/01_pipeline_requirements.md) §2. Brief summary:

- `raw.*` / `staging.*` / `ref.*` / `integration.*` — stateless rebuild
- `catalog.*` ledger + audit — stateful append-only
- `pdl_api.*` queue + call tables — stateful (cached API responses avoid re-paying for calls)

Catalog and the PDL API call cache are the only stateful subsystems. Everything else rebuilds every run.

---

## Source-of-truth hierarchy (for authors of dbt models)

When writing or editing a dbt model, read sources in this order:

1. `modeling/dbml/<schema>.dbml` — destination shape. Column names, types, nullability, uniqueness, indexes. This is the contract; the dbt SELECT column list must match.
2. [`../data_model/`](../data_model/) — column-mapping intent (which source field populates which destination column, and why).
3. PDL vendor docs — value semantics.
4. `modeling/flyway/migrations/V<n>__*.sql` — projection of DBML. NOT canonical; reference only.
5. Existing dbt models — patterns to copy, not specs to match output for.

When DBML / Flyway DDL / dbt SELECT disagree, DBML wins; the others are bugs to fix.

---

## References

- [`../requirements/01_pipeline_requirements.md`](../requirements/01_pipeline_requirements.md) §2 — refresh patterns
- [`02_pipeline_design.md`](02_pipeline_design.md) — staging conventions
- [`15_pdl_staging_design.md`](15_pdl_staging_design.md) — PDL-specific staging decisions
- [`../decisions/0001-dbml-owns-table-shape-across-layers.md`](../decisions/0001-dbml-owns-table-shape-across-layers.md)
- [`../decisions/0002-fk-enforcement-at-integration-only.md`](../decisions/0002-fk-enforcement-at-integration-only.md)
- [`../decisions/0003-staging-bulk-load-pattern-1.md`](../decisions/0003-staging-bulk-load-pattern-1.md)
- [`../decisions/0004-integration-constraint-pattern-2.md`](../decisions/0004-integration-constraint-pattern-2.md)
- [`../decisions/0005-ref-population-layer.md`](../decisions/0005-ref-population-layer.md)
- [`../decisions/0008-dbt-computed-ref-surrogate-ids.md`](../decisions/0008-dbt-computed-ref-surrogate-ids.md)
- `modeling/dbml/staging.dbml`, `modeling/dbml/integration.dbml`, `modeling/dbml/ref.dbml` — destination shape
- `processing/dbt/dbt_project.yml` — materialization config
