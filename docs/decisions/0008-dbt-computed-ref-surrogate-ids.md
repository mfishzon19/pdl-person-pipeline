# ADR-0008: Ref-table surrogate IDs + timestamps are dbt-computed, not Postgres-generated

## Context

`ref.*` tables in the V4 baseline were created with the standard Postgres pattern:

```sql
id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
...
timestamp_created   timestamptz NOT NULL DEFAULT now(),
timestamp_modified  timestamptz NOT NULL DEFAULT now()
```

That works for standalone INSERTs but conflicts with dbt-postgres's default `incremental + append` strategy. dbt's default INSERT generator (`default__get_incremental_append_sql`) builds the INSERT using `dest_columns` — the target table's **full** column list:

```sql
INSERT INTO target (id, name_lc, timestamp_created, timestamp_modified, ...)
SELECT id, name_lc, timestamp_created, timestamp_modified, ...
FROM temp_relation;
```

`temp_relation` only has whatever the dbt model SELECT produces. Ref models project the data columns (`name_lc`, FKs, etc.) but not `id` / `timestamp_*` — those are DB-managed. The INSERT then fails: `column "id" does not exist in temp_relation`.

Two ways to resolve this were considered:

### Option A. Project-wide macro override

Override `default__get_incremental_append_sql` to use **`temp_relation.columns`** instead of `dest_columns`:

```jinja
{% macro default__get_incremental_append_sql(arg_dict) %}
  {% set source_columns = adapter.get_columns_in_relation(arg_dict["temp_relation"]) %}
  {% do return(get_insert_into_sql(arg_dict["target_relation"], arg_dict["temp_relation"], source_columns)) %}
{% endmacro %}
```

The INSERT then references only what the model produced; DB-managed columns get their `DEFAULT` / IDENTITY values at insert time.

This works but pairs with `{{ config(on_schema_change='ignore') }}` on every ref model — because dbt's pre-INSERT schema-equality check would otherwise see "target has columns SELECT doesn't" and fail. Setting `ignore` skips the check, but it **skips the whole check, not just for the DB-managed columns**. The project-wide drift detector (`on_schema_change='fail'` per [ADR-0001](0001-dbml-owns-table-shape-across-layers.md)) gets punctured for every ref model.

### Option B. dbt computes IDs + timestamps; drop the IDENTITY clause

Refactor every ref model SELECT to produce the full target shape:

```sql
SELECT
  ROW_NUMBER() OVER (ORDER BY name_lc) AS id,
  LOWER(continent)                     AS name_lc,
  now()                                AS timestamp_created,
  now()                                AS timestamp_modified
FROM ...
```

`on_schema_change='fail'` works on ref models the same way it works on staging — every column accounted for. No macro needed. No per-model override needed.

Requires:
- `modeling/dbml/ref.dbml` — drop `[pk, increment]` from `id` columns; add docstring noting "dbt-computed."
- A Flyway migration (V14) to `ALTER COLUMN id DROP IDENTITY` on every existing ref table.
- Every ref model SELECT to include the `ROW_NUMBER()` + `now()` expressions.

## Decision

**Option B.**

`ref.*` surrogate `id` columns are **dbt-computed** via `ROW_NUMBER() OVER (ORDER BY <natural_key>)` in each ref model SELECT. `timestamp_created` / `timestamp_modified` are also dbt-computed via `now()`. The Postgres-side `GENERATED ALWAYS AS IDENTITY` is removed from every ref table by V14. The previously-considered project-wide macro override is deleted.

**Why B over A:**

1. **Keeps `on_schema_change='fail'` as the universal drift detector.** ADR-0001 makes DBML the source of truth and `on_schema_change='fail'` enforces that dbt SELECTs agree with DBML / Flyway DDL. Option A would have punctured that contract for 14+ ref models — a non-trivial blind spot. Drift detection has zero exceptions across staging + ref + integration under Option B.
2. **No project-wide INSERT-mechanic change.** The macro override touched every `incremental + append` model in the project (no-op for existing staging models, but the behavior change was load-bearing for any future model that didn't SELECT the full target shape). Removing the macro means the project's INSERT mechanic stays the dbt-postgres default everywhere.
3. **dbt is the only inserter into ref tables.** The original justification for DB-side IDENTITY (auto-populate id for any inserter) doesn't apply — staging+integration loaders all go through dbt; nothing else writes to ref. The cost of removing IDENTITY is theoretical.
4. **Stateless rebuild already documented surrogate IDs as unstable.** `ref.dbml` header already says *"Surrogate IDs are NOT stable across rebuilds."* Whether the IDs come from IDENTITY (resets on `TRUNCATE ... RESTART IDENTITY`) or `ROW_NUMBER` (deterministic per natural-key order within a rebuild) is functionally identical for our use case.

## Consequences

**Benefits:**

- `on_schema_change='fail'` works uniformly on every model in the project. No special cases.
- No macro override; no per-model `on_schema_change='ignore'` overrides. Project shape is simpler.
- ROW_NUMBER ordering is deterministic per rebuild (within a single delivery's data). Identical inputs → identical IDs.
- Any future ref model follows the same pattern — no architecture branch.

**Costs:**

- Every ref model SELECT is ~3 lines longer (the `ROW_NUMBER()` + 2 × `now()` expressions). Across 14 models at the time: ~42 lines of boilerplate. Tolerable.
- Surrogate IDs are now tied to dbt's row enumeration. If we ever wanted a non-dbt inserter (unlikely; nothing in the architecture suggests one), it would need to compute IDs the same way.
- V14 ALTERs existing data: pre-existing `id` values stay (no rewrite), but the next dbt rebuild's TRUNCATE+INSERT will replace them with `ROW_NUMBER` ids. Anyone holding ref ids across rebuilds is already broken (per the "unstable" contract); this just makes the rotation explicit.

**Risks:**

- `ROW_NUMBER()` is deterministic within a single rebuild — same input row order → same output IDs. **Across rebuilds**, the surrogate id assigned to a given natural-key value (e.g., country `name_lc='united states'`) may change, depending on the input row order at rebuild time. This is already documented architecture: surrogate IDs are not stable across rebuilds.

  **What this does NOT affect**: internal FK chains between ref and integration tables. ref.* and integration.* rebuild together (TRUNCATE + INSERT in DAG order); integration FKs are re-resolved via JOIN against the fresh natural keys (`name_lc` etc.) and stored as the matching new surrogate IDs. Within any pipeline state, surrogate-ID joins work correctly, and dbt models / internal queries can read across the boundary by surrogate ID with no issues.

  **What this DOES affect**: external consumers caching surrogate IDs across rebuild boundaries. If a downstream system fetches `integration.person.country_id = 5` today and stores it, the next rebuild may reassign id=5 to a different country — the cached value silently changes meaning. External consumers must either re-fetch after every rebuild, or serialize data using natural keys (`name_lc`, FK chains) instead of surrogate IDs when they intend to use it later. Same rule that applied under the previous IDENTITY-backed design; this ADR doesn't change it.

## Alternatives considered

**Option A (macro override)** — described in Context. Rejected because it punctures `on_schema_change='fail'` project-wide for ref models.

**Option C. Custom incremental_strategy scoped to ref tables.**
Write a new dbt incremental strategy (`ref_append`) that handles DB-managed columns explicitly, apply only to ref models via `materialized: incremental + incremental_strategy: ref_append`. Localizes the macro change but adds ~50-80 lines of strategy code plus per-model config wiring.

- *Rejected* because: more code than Option B's ROW_NUMBER expressions, with less architectural payoff. Still requires `on_schema_change='ignore'` per ref model (the strategy can't change schema-check semantics).

**Option D. Keep IDENTITY; use `GENERATED BY DEFAULT AS IDENTITY` instead.**
`BY DEFAULT` lets the caller supply a value or fall through to IDENTITY. Postgres no longer rejects user-supplied values.

- *Rejected* because: doesn't actually solve the problem. dbt's `on_schema_change='fail'` would still detect that target has `id` but SELECT doesn't produce it; check still fails. `BY DEFAULT` only changes the INSERT behavior, not the schema-comparison behavior.

**Option E. `INSERT ... OVERRIDING SYSTEM VALUE`.**
Postgres clause that lets you override `GENERATED ALWAYS`. Only available via custom macro — same project-wide footprint as Option A.

- *Rejected* because: same footprint as Option A without solving the schema-check puncture.

## What this falsifies / clarifies in existing docs

- `modeling/dbml/ref.dbml` — header comment + all 22 ref-table `id` column notes updated to "dbt-computed via ROW_NUMBER; not stable across rebuilds." `[pk, increment]` → `[pk]` on every id column.
- 14 ref dbt models (at the time) updated to include `ROW_NUMBER()` + `now()` expressions in their SELECT. `{{ config(on_schema_change='ignore') }}` removed from every model.
- `processing/dbt/macros/get_incremental_append_sql.sql` deleted.
- V14 migration: `ALTER COLUMN id DROP IDENTITY` on every ref table that existed at the time (22, including ones not yet populated, for consistency).

## Revisit triggers

- If we ever introduce a non-dbt inserter for ref tables (loader script, manual SQL backfill workflow). No such use case is anticipated.
- If a future ref-table design requires DB-managed columns the dbt SELECT genuinely can't compute (e.g., a Postgres-side `tsvector` for full-text search). At that point, this ADR gets reopened to evaluate macro vs. scoped strategy again.

## References

- [ADR-0001](0001-dbml-owns-table-shape-across-layers.md) — DBML as source of truth + `on_schema_change='fail'` as drift detector
- [ADR-0003](0003-staging-bulk-load-pattern-1.md) — staging bulk-load pattern; ref tables don't need Pattern 1 (small row counts)
- [ADR-0005](0005-ref-population-layer.md) — ref tables are populated by their own dbt layer in `models/ref/`
- `modeling/dbml/ref.dbml` — updated by this ADR
- `modeling/flyway/migrations/V14__ref_drop_identity_from_id.sql` — created by this ADR
- `processing/dbt/models/ref/*.sql` — 14 models updated by this ADR
- `processing/dbt/dbt_project.yml` — `+on_schema_change: fail` under `ref:` block now applies cleanly (no per-model override needed)
