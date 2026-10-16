# ADR-0002: FK enforcement at integration layer only

## Context

Three relational layers (`raw`, `staging`, `integration`) each have different lifecycle and semantic characteristics:

- `raw` is populated row-by-row by the S3 ingester. Cross-table FKs in raw aren't meaningful — each table is a 1:1 dump of one source's records.
- `staging` is TRUNCATE+rebuilt on every dbt run via `incremental + append` with a `pre_hook: TRUNCATE`. Sibling staging models populate in parallel from the dbt DAG, not in FK dependency order.
- `integration` is where the relational backbone lives — person ↔ employment ↔ company. Business consumers query this layer; referential integrity matters for joins.

The question: where do we enforce foreign-key constraints, and where are they merely informational?

## Decision

**No enforced FKs in `raw` or `staging`. FKs declared and enforced only in `integration`.**

Specifically:
- `raw.*` tables: no FK constraints in DBML or Flyway DDL.
- `staging.*` tables: no FK constraints in Flyway DDL. DBML may declare refs **for ERD readability**, but the Flyway generator either suppresses FK DDL for the staging schema or we author refs as comments. (Default: omit refs in staging DBML to keep DBML→Flyway translation trivial; rely on `*_pdl_id` / `*_company_id` naming convention to convey cross-table relationships visually.)
- `integration.*` tables: FKs fully declared in DBML and created by the Flyway migrations.

`ref.*` tables, added later ([ADR-0005](0005-ref-population-layer.md)), also carry FKs (e.g. `ref.city.country_id → ref.country`) and follow the integration rule. How FKs on both schemas survive the stateless rebuild (dropped before, recreated `NOT VALID` after, with dbt `relationships` tests as the row-level check) is [ADR-0009](0009-fk-constraint-drop-recreate-for-rebuild.md).

## Consequences

**Why no FKs in staging:**

1. **Mechanical.** Staging is TRUNCATE+rebuild parallel from raw. dbt loads `staging.pdl_person_parsed` and `staging.pdl_person_experience_parsed` concurrently — no FK ordering can be cheaply maintained between them. Forcing FK order would serialize the load or require deferred-constraint gymnastics that don't even help (PG's deferred FK doesn't skip index work).
2. **Semantic.** A staging FK violation means upstream data (PDL) is internally inconsistent — a `person_pdl_id` in `experience[]` that doesn't match the person record. That's a data-quality signal, better caught by a dbt data test (`relationships` test) than by a Postgres constraint that aborts the load mid-stream.
3. **Performance.** FK validation is a per-row indexed lookup on the parent table. Skipping it on staging INSERTs of tens of millions of rows is a meaningful component of bulk-load speedup.

**Why FKs are required in integration:**

1. **Source of truth for analytics.** Business consumers join across integration tables. They need referential integrity guarantees — an `integration.experience.person_id` should always resolve to an `integration.person.id`.
2. **Modeling discipline.** Hard-enforced FKs make schema errors surface immediately during the load rather than silently propagating into downstream consumers.
3. **Load ordering exists.** Integration is built from staging in a structured DAG (parents like `person` and `company` first, then `experience` referencing both). dbt's `ref()` produces correct ordering.

**What this gives us:**
- Staging bulk loads aren't blocked by FK validation overhead
- Data-quality signal from PDL's internal inconsistency surfaces as dbt test results, where we can triage, not load aborts
- Integration retains hard relational guarantees for analytic consumers
- ERDs remain readable — DBML still declares refs in integration, conveying the relational backbone visually

**What we accept:**
- Staging tables look "loose" in the ERD if refs are omitted. Mitigated by column naming convention (`*_pdl_id`, `*_company_id`).
- Cross-table consistency in staging must be enforced via dbt tests, not the database. (More flexible but adds test-authoring discipline.)

## Alternatives considered

- **FKs everywhere, including staging.** Pros: most rigorous; staging FK violation aborts the load before bad data lands. Cons: serializes parallel staging loads; doubles bulk-load cost; surfaces upstream PDL inconsistency as an opaque error rather than an actionable test failure. Rejected — wrong tradeoff for an intermediate layer.

- **DEFERRABLE INITIALLY DEFERRED in staging.** PG checks at commit, not row. Pros: allows out-of-order INSERTs within a transaction. Cons: doesn't skip the unique-index work (PG enforces uniqueness via the index, which is updated per row regardless of deferral); minimal perf savings for staging-shaped loads; adds DDL complexity for negligible benefit. Rejected.

- **No FKs anywhere.** Cons: integration consumers lose referential integrity; bad data in one integration table propagates silently to joiners. Rejected — integration is exactly where we want the guarantees.

## Related

- [ADR-0001](0001-dbml-owns-table-shape-across-layers.md) — DBML still owns shape; this ADR refines what's in that shape per layer
- [ADR-0003](0003-staging-bulk-load-pattern-1.md) — Staging bulk-load relies on FK-free INSERTs being fast
- [ADR-0009](0009-fk-constraint-drop-recreate-for-rebuild.md) — How ref / integration FKs are handled around each rebuild
