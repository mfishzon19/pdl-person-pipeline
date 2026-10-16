# ADR-0010: Extend dbt-computed surrogate IDs from `ref.*` to `integration.*`

## Context

[ADR-0008](0008-dbt-computed-ref-surrogate-ids.md) established that `ref.*` tables compute `id` (and `timestamp_created` / `timestamp_modified`) in the dbt model SELECT — not via Postgres-side `GENERATED ALWAYS AS IDENTITY`. The reason was preserving `on_schema_change='fail'` as the project-wide drift detector for ADR-0001: a target table with a column the dbt SELECT can't produce always trips that check.

ADR-0008 was scoped to `ref.*` and shipped as V14 because no `integration.*` dbt models existed at the time. The integration tables stayed on `GENERATED ALWAYS AS IDENTITY` from the V6 baseline.

That changes the moment the first integration dbt model is authored. Authoring `processing/dbt/models/integration/person.sql` hit exactly the symptom ADR-0008 describes — `incremental + append + on_schema_change='fail'` requires the SELECT to project every destination column including `id` / `timestamp_*`, but IDENTITY columns reject explicit values.

## Decision

Extend ADR-0008's mechanism to **all `integration.*` tables**.

- Every `integration.*` table with an `id` surrogate column loses its `GENERATED ALWAYS AS IDENTITY` clause (V20: 10 tables in one atomic migration). Column stays as `bigint NOT NULL PRIMARY KEY`.
- Every integration dbt model projects `id`, `timestamp_created`, `timestamp_modified` explicitly in its SELECT.
- `id` uses `ROW_NUMBER() OVER (ORDER BY <natural_key>)`. Natural key choice is per-table:
  - Tables with a pdl-style natural key (`pdl_id` / `pdl_company_id`): order by that column.
  - Tables without one (junction-with-surrogate tables: `experience`, `person_education`): order by the upstream staging composite natural key carried through the SELECT, decided at model-authoring time and documented in the model's leading comment block.
- `timestamp_created` / `timestamp_modified` use `now()`.

Pure-junction tables (composite PKs, no surrogate `id` — e.g. `integration.person_country`, `person_skill`, `experience_industry`) are unaffected. They already match the dbt INSERT shape exactly.

## Consequences

**Benefits:**

- `on_schema_change='fail'` now enforces drift detection uniformly across staging, ref, AND integration. No exception schemas.
- Every integration model follows one INSERT pattern. Cross-layer cognitive load drops to zero.
- The macro-override / `OVERRIDING SYSTEM VALUE` workarounds discussed (and rejected) in ADR-0008 stay rejected — same reasoning applies here.

**Costs:**

- Integration surrogate IDs are no longer stable across rebuilds. Same constraint as `ref.*`; the project already documents this contract (every integration.dbml header note + the [requirements/01 §2](../requirements/01_pipeline_requirements.md) stateless rebuild section). Downstream consumers must use natural keys (pdl_id / pdl_company_id / catalog.person_key_map.internal_person_id), not integration surrogate ids.
- Every future integration model author must remember to project `id` + `timestamp_*` in the SELECT. ADR-0001's `on_schema_change='fail'` is the safety net — drift fails the build.

## What this ADR is NOT — identity resolution

This ADR governs the **mechanism** by which `integration.*.id` is computed (dbt-side ROW_NUMBER, not Postgres IDENTITY). It does **not** decide what value that `id` should hold.

Per [ADR-0007](0007-integration-current-state-ledger-history.md) + [requirements/01 §4.2](../requirements/01_pipeline_requirements.md), the target design says `integration.person.id` is the stable `internal_person_id` from `catalog.person_key_map`, looked up via `identity_signature` (whose construction is still an open decision; [design/02 §9](../design/02_pipeline_design.md#9-identity-ledger) sketches one option). The same JOIN pattern applies to every integration entity table.

**That JOIN is deferred to future identity-resolution work.** Reasons for deferring:

1. **There is no current consumer** of `integration.person.id`. No external system stores it; no application code joins to it. The rebuild-unstable id is inert until one exists.
2. **A minimal person_key_map population would be a half-measure.** It would handle only the trivial outcome (every PDL row is a new person, gets a new `internal_person_id`) and skip the hard ones (merges across deliveries, ambiguous matches, unsignable records). Full identity resolution has to rewrite the population logic anyway to add those outcomes plus the probabilistic-matching decision — no real labor is saved by building the trivial path now.
3. **The `identity_signature` contract benefits from being designed with the hard cases in scope.** Picking hash inputs and NULL handling in isolation risks a signature shape that doesn't extend cleanly.

**What this means concretely for identity-resolution implementers:**

- `integration.person.id` is `ROW_NUMBER() OVER (ORDER BY pdl_id)`. That SELECT expression is the one line that changes — swap it for a JOIN against `catalog.person_key_map.internal_person_id`. All downstream FK tables (`integration.experience.person_id`, `integration.person_education.person_id`, every junction) rebuild from the same dbt DAG run, so the id space transitions atomically. No data migration needed.
- The downstream FK chain is internally consistent within a single rebuild and will remain internally consistent after the swap. The values change; the topology doesn't.
- The same mechanism extends to `integration.company.id`, `integration.school.id`, `integration.experience.id`, etc. The swap can cover every integration table at once or go model-by-model — implementer's call.

## Alternatives considered

The alternatives are identical to ADR-0008's Options A / C / D / E (project-wide macro override; scoped incremental strategy; `GENERATED BY DEFAULT AS IDENTITY`; `OVERRIDING SYSTEM VALUE`). All rejected for the same reasons: they puncture the schema-equality check or solve a different problem. See ADR-0008 §"Alternatives considered" for the full enumeration — re-arguing them here would duplicate that analysis.

**One narrow alternative specific to this ADR**: keep IDENTITY on integration.* and migrate tables one change at a time, each future integration-model change carrying its own DROP IDENTITY. Rejected because:

- The tables were all empty at the time (zero data risk for the batch ALTER).
- Spreading 10 ALTERs across as many separate changes adds review surface area for no benefit.
- During the migration window, `integration.*` would have two id-generation patterns simultaneously — confusing for any author who looks at one table for a template.

## References

- [ADR-0001](0001-dbml-owns-table-shape-across-layers.md) — `on_schema_change='fail'` is the universal drift detector.
- [ADR-0008](0008-dbt-computed-ref-surrogate-ids.md) — original decision this ADR extends. Full reasoning lives there.
- `modeling/flyway/migrations/V20__integration_drop_identity_and_person_scalar_address.sql` — created by this ADR (10 DROP IDENTITY statements bundled with the unrelated `integration.person` address-scalar refactor).
- `modeling/dbml/integration.dbml` — every `id` column flipped from `[pk, increment]` → `[pk]` with a note pointing back to this ADR + V20.
- `processing/dbt/models/integration/person.sql` — first model adopting the pattern; serves as the template for the rest.
