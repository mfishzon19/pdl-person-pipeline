# ADR-0003: Staging bulk-load via Pattern 1 (post-hook drop / recreate of indexes)

## Context

Staging dbt models (PDL: `pdl_person_parsed`, `pdl_person_experience_parsed`, `pdl_person_education_parsed`, ...) flatten raw JSONB into wide relational tables via `JSON_TABLE`. Output cardinality is large: a full delivery has millions of persons, and the experience and education unnests are several times larger again (tens of millions of rows).

The materialization pattern is `incremental + append + pre_hook: TRUNCATE`. Each dbt run TRUNCATEs the target staging table then INSERTs the full SELECT output. On a small (2-core) Postgres host this produced two consistent problems:

- Bulk INSERT into a pre-indexed table is dominated by per-row index maintenance. With 3 indexes on `pdl_person_experience_parsed`, every inserted row means 3 b-tree updates serialized through WAL.
- Several staging models running concurrently (`dbt --threads 4`) saturated CPU + memory, and some died with `server closed the connection unexpectedly`.

Moving to a 4 vCPU / 16 GB host roughly tripled throughput on its own. The question: is there an application-layer optimization on top of the hardware upgrade that produces additional speedup?

## Decision

**Apply Pattern 1 to every staging-layer dbt model: drop the indexes and PK in a `pre_hook` before the TRUNCATE+INSERT, recreate them in a `post_hook` after.**

Mechanically (per model in `dbt_project.yml`):

```yaml
pre_hook:
  - "DROP INDEX IF EXISTS staging.idx_<table>_<col1>"
  - "DROP INDEX IF EXISTS staging.idx_<table>_<col2>"
  # ... one per index
  # The parent staging-level TRUNCATE pre_hook is preserved and accumulates.
post_hook:
  - "CREATE INDEX idx_<table>_<col1> ON {{ this }} USING btree (<col1>)"
  - "CREATE INDEX idx_<table>_<col2> ON {{ this }} USING btree (<col2>)"
  # ... one per index
  - "ANALYZE {{ this }}"
```

PK and UNIQUE constraints (the `_unique` tables carry a UNIQUE constraint on their natural key) follow the same recipe:

```yaml
pre_hook:
  - "ALTER TABLE {{ this }} DROP CONSTRAINT IF EXISTS <table>_pkey"
  # plus the DROP INDEX statements
post_hook:
  - "ALTER TABLE {{ this }} ADD PRIMARY KEY (<col_a>, <col_b>)"
  # plus the CREATE INDEX statements + ANALYZE
```

The `ADD PRIMARY KEY` after the INSERT is a single sort-and-build, which both checks uniqueness (build fails on duplicates) and is much faster than per-row b-tree maintenance during the INSERT.

The DBML-declared index list and the dbt-declared hook list are intentionally duplicated. Reviewers verify they match whenever either side changes. If the duplication starts costing us (~30+ tables), generate the dbt-side SQL from DBML JSON via `dbml-cli` as a build step.

## Consequences

**Measured impact.** A psql spike on one model (`pdl_person_experience_parsed`, full delivery, 4 vCPU / 16 GB host, default Postgres parameters) compared A — indexes maintained during the INSERT — with B — Pattern 1. The bare INSERT without index maintenance was roughly 1.8× faster; the post-INSERT `CREATE INDEX` phase gave back about half of that, for a net wall-time improvement of roughly 1.3×. The same hooks run through dbt's real materialization path showed the same result within a few percent.

**What this gives us:**
- A meaningful cut in staging rebuild time, scaling across every large staging model.
- Atomic — the dbt model's transaction wraps pre_hook → INSERT → post_hook. A failed PK / UNIQUE build rolls back the load. No "data loaded without constraint" window.
- Pattern is uniform across all staging models. New staging models inherit the recipe.

**What we accept:**
- Two sources for the index / constraint list (DBML and dbt config). Code review catches divergence. Tooling escape hatch exists if scale demands it.
- Post-hook `CREATE INDEX` time eats about half the bare-INSERT savings under default Postgres parameters. Raising `maintenance_work_mem` and `max_parallel_maintenance_workers` compresses this (see Validation).
- Hook ordering: parent `staging`-level `pre_hook: TRUNCATE` runs *before* the model-level DROP INDEX statements (dbt parent-first hook order). Functionally fine — both finish before the INSERT — but the order is "TRUNCATE then DROP" not "DROP then TRUNCATE." Documented here so the order isn't a surprise.

**What this does NOT solve:**
- Slow dbt `not_null` tests on the largest staging tables (sequential scans with no supporting index). Parameter tuning helps substantially (see Validation); sampled tests or test-specific partial indexes remain options.

## Alternatives considered

- **No change (just upgrade the database host).** Pros: zero application-layer work. Cons: leaves a measured improvement on the table. Rejected — the dbt-config addition is small and the savings compound across every large staging table.
- **Pattern 2 (custom materialization for `models/constraints/*.sql`).** Pros: constraints are first-class DAG nodes; allows reapplying without rerunning the load. Cons: custom materialization machinery is overkill for staging where there's exactly one PK + N indexes per table and no cross-staging FKs. Was proposed for the integration layer instead ([ADR-0004](0004-integration-constraint-pattern-2.md), never implemented; FK handling ended up as [ADR-0009](0009-fk-constraint-drop-recreate-for-rebuild.md)).
- **dbt model contracts (`materialized: table` with declared constraints in `schema.yml`).** Cons: doesn't fit our `incremental + append + pre_hook: TRUNCATE` pattern; contracts work on table materialization which DROP CREATEs the table each run, which we explicitly don't do (DBML+Flyway own table creation per [ADR-0001](0001-dbml-owns-table-shape-across-layers.md)). Rejected.
- **DEFERRABLE INITIALLY DEFERRED PK on staging.** PG enforces uniqueness via the unique index regardless of deferral — deferring only delays *when* the conflict error raises, not the per-row index work. Doesn't help bulk-load perf. Rejected; see also [ADR-0002](0002-fk-enforcement-at-integration-only.md).
- **UNLOGGED staging tables (skip WAL).** Orthogonal optimization, complementary to Pattern 1, deliberately separated from this ADR to keep the decision unit small. May land in a follow-up ADR if a future spike shows meaningful additional savings.

## Validation

**Round 1 — default parameters.** The A / B spike above, plus a single-model `dbt build` confirming the hook plumbing works end-to-end through dbt.

**Round 2 — tuned parameters, full layer, parallel.** Most of the recommended parameter changes were applied (`maintenance_work_mem` 2 GB, `max_wal_size` 8 GB, `max_parallel_workers_per_gather` 4, `track_io_timing` on, `wal_compression` lz4, `max_connections` 30; `io_method=worker` because `io_uring` wasn't available in that Postgres 18 build). Then: ingest a full delivery → `dbt build --select tag:pdl --threads 4` with every PDL staging model in parallel under Pattern 1.

- The whole staging layer built and all dbt tests passed, with no `server closed the connection` failures (the dominant failure mode on the 2-core host).
- End-to-end (ingest + staging) was roughly 4× faster than the extrapolated 2-core baseline.
- `not_null` tests on the largest tables dropped from tens of minutes to under two minutes each.
- **Worth knowing for capacity planning:** under `--threads 4` the heaviest single model ran *slower* than in the single-model spike, because concurrent models compete for CPU and WAL during their `CREATE INDEX` phases. Parallelism wins on total layer wall time (about 2.5× versus running the models sequentially), not on per-model wall time. Plan for layer-level wall time.

At the time the layer also had `_certifications_parsed`, `_languages_parsed` and `_profiles_parsed` models. The first two produced zero rows (PDL's delivery doesn't emit those arrays), and profiles had no usable key ([design/15](../design/15_pdl_staging_design.md)); all three were dropped later (V10, V11).

## Related

- [ADR-0001](0001-dbml-owns-table-shape-across-layers.md) — DBML retains source-of-truth for staging shape; this ADR adds dbt-side runtime DDL on top
- [ADR-0002](0002-fk-enforcement-at-integration-only.md) — Pattern 1 is FK-free because staging has no FKs
- [ADR-0009](0009-fk-constraint-drop-recreate-for-rebuild.md) — the cross-schema FK counterpart ("Pattern 2 for FK")
