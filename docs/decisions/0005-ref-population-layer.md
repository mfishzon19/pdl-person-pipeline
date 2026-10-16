# ADR-0005: Ref tables are populated by their own dedicated dbt layer

## Context

The pipeline has four schemas in play during a dbt build:

- `raw.*` — lands ingested JSON
- `staging.*` — typed flatten + dedup + alias-resolve
- `integration.*` — denormalized conformed entities with FKs
- `ref.*` — controlled vocabularies (`ref.skill`, `ref.job_title_role`, `ref.city`, `ref.seniority_level`, `ref.industry`, etc.)

Two questions need answers before authoring any `_unique` or integration model:

1. **Which layer populates ref tables — staging or integration?**
2. **What refresh pattern do ref tables follow — stateless rebuild (TRUNCATE + INSERT DISTINCT every run) or append-only upsert (INSERT … ON CONFLICT DO NOTHING)?**

Documentation and implementation disagreed prior to this ADR:

- `modeling/dbml/staging.dbml` header comment (the simple-text-array block) implied append-only upsert at "the ref upsert layer."
- `processing/dbt/dbt_project.yml` actually wired ref tables with the same stateless rebuild materialization as staging and integration:

```yaml
ref:
  +materialized: incremental
  +incremental_strategy: append
  +pre_hook: "TRUNCATE TABLE {{ this }} RESTART IDENTITY CASCADE"
  +on_schema_change: fail
```

This ADR locks the answer and brings docs in line.

## Decision

**Ref tables are populated by dedicated dbt models in `processing/dbt/models/ref/`, via stateless rebuild.**

Mechanically:

- **Population layer:** dedicated ref dbt models in `processing/dbt/models/ref/`. Each ref table has its own `.sql` model that reads from staging (`_staged` tier when it exists; otherwise `_unique` / `_parsed`) and emits DISTINCT vocab. Staging dbt models never touch ref. Integration dbt models JOIN to ref tables for FK resolution but don't populate them.
- **Refresh pattern:** stateless rebuild. Same materialization as integration: `incremental` + `incremental_strategy: append` + `pre_hook: TRUNCATE`. Surrogate IDs reset every run; integration FKs resolve in the same DAG run, so the reset doesn't leak.
- **Staging→ref unpack line:** simple text arrays (skills, interests, title.levels, degrees, majors, minors, etc.) live as jsonb columns on the parent staging table. They are NOT broken out into separate staging tables. The ref models unnest them via `jsonb_array_elements_text()`; integration models then JOIN to ref for FKs.

The split per layer (per [requirements/01 §2](../requirements/01_pipeline_requirements.md)):

| Layer | Refresh | Who populates |
|---|---|---|
| `raw.*` | Stateless rebuild | Ingester (TRUNCATE + COPY per delivery) |
| `staging.*` | Stateless rebuild | dbt models in `processing/dbt/models/staging/` |
| `ref.*` | Stateless rebuild | dbt models in `processing/dbt/models/ref/` (NOT staging, NOT integration) |
| `integration.*` | Stateless rebuild | dbt models in `processing/dbt/models/integration/` |
| `catalog.*` ledger | Stateful append-only | `raw.project_pdl_deltas()` projection |

## Consequences

**Cost paid:**

- Ref tables are rebuilt every dbt run. Surrogate IDs are reassigned (`ref.skill.id` for "python" may differ between rebuilds). FKs in integration resolve correctly because integration is rebuilt in the same DAG run.
- Ref tables are not persistent stores of "every vocab value we've ever seen." If a value drops out of every source on a given month, it disappears from ref until a source re-emits it.

**Benefits:**

- Same materialization principle as staging + integration. "Stateless content rebuild, stateful identity ledger" applies uniformly to everything except the catalog ledger. No special case to remember.
- No ON CONFLICT logic. Less code, less to debug.
- Ref tables can't drift from current source data. A value present in `ref.skill` is guaranteed to be present in at least one integration row this run.

**Risks we accept:**

- If a future external canonical source feeds a ref table directly (gov location data, ISO 3166 codes, ONET occupational classifications, manually curated taxonomies), stateless rebuild becomes wrong for those tables. The canonical source's stable IDs must persist across rebuilds; integration data alone can't reconstruct them. When that source arrives, the affected ref tables flip to append-only (`INSERT … ON CONFLICT DO NOTHING`), and the canonical seed loads from a dbt seed file or one-time migration.
- Surrogate IDs are not stable across rebuilds. Any consumer that caches a `ref.<table>.id` value across runs will get wrong answers. Current consumers (integration tables) resolve FKs at build time, so this is fine. If anything ever caches ref IDs externally, that consumer is broken.

**Constraints on future work:**

- Adding a new ref table to support an integration model means: (a) define the ref table in `modeling/dbml/ref.dbml`, (b) Flyway migration to create it, (c) dbt ref model in `processing/dbt/models/ref/<name>.sql` doing `SELECT DISTINCT … FROM <staging_staged_or_parsed_table>`, (d) the integration model JOINs to it for FK resolution.
- Staging models stay focused on "data as PDL emits it." Vocab extraction belongs in the ref layer.

## Alternatives considered

**A. Append-only ref upsert via `INSERT … ON CONFLICT DO NOTHING`.**
This was the documented intent (per the stale staging.dbml comment) but not the implementation. Stateless rebuild was already wired in `dbt_project.yml`. Rejected because: same correctness outcome under current architecture (integration FKs resolve in the same run regardless), but adds ON CONFLICT logic plus persistent state to a system whose only stateful subsystem is the catalog ledger. The architectural simplicity of "only the ledger is stateful" is worth more than vocab preservation.

**B. Ref populated by staging dbt models.**
Rejected because it couples staging (one-source-per-table) to ref (cross-table vocabulary). Several PDL staging tables already feed the same ref table (e.g. `ref.industry` from person, experience, and API company data), and any future source would add more. A dedicated ref layer makes that UNION trivial. Forcing staging models to know about ref also breaks the staging convention (`parsed → unique → staged`, no cross-layer side effects).

**C. Hybrid — some ref tables stateless, others append-only.**
Rejected because no ref table currently has a canonical external source. Revisit if/when one does. Mixing patterns now adds complexity without a use case.

## Revisit triggers

- An external canonical source feeds any ref table (gov data, ISO codes, ONET, manually curated taxonomies). Flip the affected tables to append-only at that point.
- A consumer outside the dbt DAG needs stable ref surrogate IDs across rebuilds (e.g., cached lookups in an API layer). Switch the affected tables to append-only and add the stability contract to a successor ADR.

## References

- `modeling/dbml/staging.dbml` — header convention + simple-text-array comment, both updated in the same change as this ADR.
- `processing/dbt/dbt_project.yml` — ref materialization (stateless rebuild).
- [requirements/01 §2](../requirements/01_pipeline_requirements.md) — refresh patterns per layer table.
- [ADR-0001](0001-dbml-owns-table-shape-across-layers.md) (DBML owns table shape across layers) — establishes that ref tables, like staging and integration, are Flyway-owned for DDL.
