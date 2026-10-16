# ADR-0001: DBML owns table shape across raw / staging / integration

## Context

Three Postgres schemas form the relational layers of the warehouse:

- `raw` — ingested PDL source data (Person bulk deliveries + delta files), one row per source record
- `staging` — cleansing/confirmation layer; light transformations of raw (JSON unnest, type casts, NULL filtering)
- `integration` — final normalized source of truth; relational backbone (person, employment, company)

For every table in these layers, three artifacts can describe it:
- DBML in `modeling/dbml/<schema>.dbml` (declarative contract — column types, nullability, indexes, refs)
- Flyway migration in `modeling/flyway/migrations/V_n_*.sql` (generated from DBML; applied to Postgres)
- dbt model in `processing/dbt/models/<layer>/*.sql` (the SELECT that populates it)

The question: which one is the source of truth for table shape?

The answer is DBML. This ADR records *why* and pins the boundary so we don't accidentally drift to dbt-owns-everything or hand-author migrations bypassing DBML.

## Decision

**DBML is the source of truth for table shape in `raw`, `staging`, and `integration` schemas.**

Mechanically:
- Each table block in DBML defines columns, types, nullability, PK, indexes.
- Flyway migrations are a projection of DBML. The intended generator (`modeling/scaffolding/`) is not built, so migrations are hand-authored against the DBML for now; generated files, once they exist, are never hand-edited.
- dbt models SELECT in the shape DBML declares. `on_schema_change = 'fail'` on the materialization catches drift mechanically.
- DBML refs (foreign-key arrows) document relationships in the ERD even where the FK is not enforced (see [ADR-0002](0002-fk-enforcement-at-integration-only.md)).

## Consequences

**What this locks us into:**
- Every new table starts in DBML. Adding a staging table = author the DBML block, regenerate Flyway, apply migration, then write the dbt SELECT.
- Adding a column = three-file change (DBML + Flyway migration + dbt schema.yml / SELECT). `on_schema_change=fail` catches drift; reviewers catch the rest.
- A duplication tax exists for PKs and indexes (DBML declares them; dbt's post-hook recreates them — see [ADR-0003](0003-staging-bulk-load-pattern-1.md)). At ~30+ tables this becomes noticeable; the escape hatch is generating dbt-side constraint SQL from DBML JSON via `dbml-cli`. Defer until the duplication actually bites.

**What this gives us:**
- **Spec clarity.** When any data engineer authors a model (e.g. new staging models), the DBML block IS the spec. They write the SELECT to match; reviewers don't have to mentally reconstruct the target from the SELECT.
- **ERD as durable documentation.** dbdocs/dbdiagram render the DBML; cross-table relationships are visible without grep'ing the codebase. dbt's lineage graph is model-level, not column-level — it can't show ref arrows.
- **Reproducibility.** Database schema state is a deterministic function of versioned DBML + Flyway migrations. Re-applying Flyway to an empty DB rebuilds the exact schema.

**What becomes harder:**
- Iterating on a column shape requires the three-file change. Acceptable cost for what we get.
- Anyone who doesn't know about the convention may bypass DBML by hand-authoring a Flyway migration — discoverable via code review only.

## Alternatives considered

- **dbt-owns-everything (`materialized: table`).** dbt CREATE TABLEs on every run with `models/<layer>/*.sql` as the only spec. Pros: one file changes per model, no three-file sync, naturally side-steps bulk-load constraint maintenance (DROP CREATE has no preexisting indexes to maintain). Cons: loses DBML ERD + cross-team contract; hot-swap risk for readers during the brief CREATE window; harder for non-dbt tools (analyst SQL, BI) to discover the schema; doesn't fit our existing `incremental + append + pre_hook: TRUNCATE` pattern. Rejected because the spec-clarity and ERD value outweighs the three-file cost at our scale.

- **Hand-written Flyway migrations, no DBML.** Direct authoring of `V_n__*.sql`. Cons: no ERD, no single canonical view of schema shape, no `on_schema_change` enforcement. Loses every benefit of the contract. Rejected.

- **Mixed: DBML for raw/catalog, dbt for staging/integration.** Pros: smaller DBML surface; staging models become single-file. Cons: introduces a per-layer boundary that's hard to reason about; ERD breaks for relationships that span layers (staging.experience.company_pdl_id → integration.company.pdl_company_id wouldn't render); future schema migrations across layers become awkward. Rejected — the uniform "DBML owns all three" rule is simpler.

## Related

- [ADR-0002](0002-fk-enforcement-at-integration-only.md) — FK enforcement boundary
- [ADR-0003](0003-staging-bulk-load-pattern-1.md) — Staging bulk-load mechanism
- [ADR-0009](0009-fk-constraint-drop-recreate-for-rebuild.md) — How FK constraints are handled around each rebuild
- [design/02 §11](../design/02_pipeline_design.md) — Flyway/dbt ownership contract (the running reference; this ADR captures the decision behind it)
