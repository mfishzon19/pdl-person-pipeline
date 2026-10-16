# ADR-0004: Integration constraints via Pattern 2 (custom materialization)

> Superseded by [ADR-0009](0009-fk-constraint-drop-recreate-for-rebuild.md); never implemented.

## Context

The integration layer is the relational backbone — entity tables like `person`, `company`, `employment` with real FK relationships between them. Per [ADR-0002](0002-fk-enforcement-at-integration-only.md), this is the layer where FKs are *enforced*, not merely documented.

Pattern 1 ([ADR-0003](0003-staging-bulk-load-pattern-1.md)) handles single-table bulk loads with one PK + N non-PK indexes per table. It works well when constraints are local to a single model.

Integration introduces a structural difference: a single dbt run touches multiple tables that reference each other. Loading `employment` requires `person` and `company` already populated *and* their PKs in place. FKs from `employment` must be applied after `employment` itself is loaded. Pattern 1's "all constraints in one model's post-hook" doesn't capture this dependency structure cleanly — and reapplying just an FK (e.g., after a data fix) requires rerunning the whole model.

The question: how do we declare and apply constraints in the integration layer in a way that makes dependency order explicit and lets each constraint be addressed individually?

## Decision

**Apply integration-layer PKs and FKs as separate dbt models under `processing/dbt/models/integration/constraints/`, each using a custom `materialized: 'constraint'` materialization. Each constraint is its own DAG node, ordered by `ref()` to its dependency data model(s).**

Each constraint model is small — typically 3 lines — and looks like:

```sql
-- models/integration/constraints/employment__fk_person.sql
{{ config(materialized='constraint') }}

ALTER TABLE {{ ref('employment') }}
  ADD CONSTRAINT employment_person_fk
  FOREIGN KEY (person_id) REFERENCES {{ ref('person') }}(person_id)
```

The `constraint` materialization (defined once in `processing/dbt/macros/`) wraps a single `ALTER TABLE` and treats success as the model "materialized." The `ref()` to both `employment` (the FK source) and `person` (the FK target) places this constraint downstream of both data models in the dbt DAG.

Layered with Pattern 1 ([ADR-0003](0003-staging-bulk-load-pattern-1.md)) for the table-local PK + indexes, the result is:

```
person (data model)             company (data model)
        |                                |
person__pk (constraint)          company__pk (constraint)
        |                                |
              employment (data model — references both via FK)
                         |
              employment__pk (constraint)
                         |
        employment__fk_person, employment__fk_company (constraints)
```

dbt's DAG ordering is automatic from `ref()`. `dbt run --select integration` builds in dependency order. `dbt run --select employment__fk_person` reapplies just that FK without rerunning anything else — useful after a data fix or constraint name change.

## Consequences

**What this gives us:**
- **Constraint application is visible in the DAG.** New engineers see the ordering, can trace "what depends on what" without reading model bodies.
- **Selective reapply.** A failed FK build (e.g., orphan rows discovered after the fact) is fixed by `dbt run --select <fk_constraint>` once the data is repaired. No full reload.
- **Per-constraint review surface.** Each ALTER TABLE is its own file, its own diff line. Easier to spot a typo in `REFERENCES other_table(wrong_column)`.
- **Parallel constraint creation.** Independent constraint nodes (e.g., `employment__fk_person` and `employment__fk_company`) can run in parallel when dbt's `--threads N > 1`.
- **Lifecycle hygiene.** Renaming, dropping, or modifying a constraint becomes a deliberate, reviewed file change, not a stealth schema edit.

**What we accept:**
- File count grows with constraint count. For ~30 integration tables and average 2 FKs per table + 1 PK per table → ~90 constraint files. Each is 3 lines; grep-able by naming convention (`*__pk.sql`, `*__fk_*.sql`).
- Constraint duplication with DBML — same trade-off as Pattern 1 (DBML declares the FK in `Ref:` syntax; dbt model recreates it as DDL). Generate-from-DBML escape hatch applies symmetrically.
- Constraint failure during the build is detected at the constraint node (not the data load). A failed FK leaves the parent data model populated but the FK absent. Re-run the constraint node after fixing the offending data; partial state is visible via DAG node status.
- Custom materialization is one-time machinery to author (~30 lines of macros). Cost is paid once.

**What we explicitly avoid:**
- Mixing constraint DDL into the data model's post-hook (Pattern 1) at the integration layer. Works for staging where constraints are intra-model, but obscures cross-table FK ordering. Better to make the DAG explicit.
- Postgres deferrable constraints. PG defers *when* the conflict raises, not the per-row index work. Pattern 2 already addresses ordering via the DAG; deferrable adds no value here.
- A standalone "apply all FKs" post-build script. Reintroduces opacity (which FKs? which tables? in what order?) and breaks dbt's DAG semantics.

## Status note

This pattern was accepted before any integration model existed and was **never implemented**: there is no `models/integration/constraints/` directory and no `constraint` materialization. Integration FKs are declared in DBML and created by the Flyway migrations. Running dbt with `--threads 4` then hit `TRUNCATE ... CASCADE` deadlocks across those FKs, and the chosen fix was [ADR-0009](0009-fk-constraint-drop-recreate-for-rebuild.md): drop all `ref` / `integration` FKs at `on-run-start` and recreate them `NOT VALID` at `on-run-end`, with dbt `relationships` tests as the integrity check. The `employment` table in the examples below is illustrative; the real table is `integration.experience`.

## Alternatives considered

- **Pattern 1 (post-hook on the data model) for integration too.** Pros: zero new dbt machinery; same recipe as staging. Cons: FK ordering is implicit in post-hook execution order; no DAG visibility; reapplying a constraint without rerunning the load isn't possible. Rejected — integration's multi-table dependencies benefit from explicit DAG nodes.
- **dbt's `constraints:` block in `schema.yml` (model contracts).** Pros: declarative; native dbt. Cons: tied to `materialized: table` which DROP-CREATEs the table each run, conflicting with DBML+Flyway ownership ([ADR-0001](0001-dbml-owns-table-shape-across-layers.md)) and the bulk-load-friendly `incremental + append` strategy. Rejected.
- **A separate post-build SQL script that applies all FKs in one transaction.** Cons: opaque; not in the DAG; selective reapply impossible; new engineers don't see the ordering. Rejected.

## Related

- [ADR-0001](0001-dbml-owns-table-shape-across-layers.md) — DBML still owns the integration shape; this ADR is about runtime application
- [ADR-0002](0002-fk-enforcement-at-integration-only.md) — Why FKs exist here in the first place
- [ADR-0003](0003-staging-bulk-load-pattern-1.md) — Pattern 1 for staging; Pattern 2 is its integration-layer counterpart
- [ADR-0009](0009-fk-constraint-drop-recreate-for-rebuild.md) — the approach that replaced this one
