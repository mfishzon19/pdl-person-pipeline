# modeling/scaffolding/

Python compiler that turns DBML into Flyway migrations and dbt artifacts.

## Status

**Not implemented yet.** DBML and Flyway migrations are hand-authored side by side, with each DBML/SQL pair kept in sync manually (e.g. `catalog.dbml` ↔ `V1__catalog_baseline.sql`, `raw.dbml` ↔ `V2__raw_baseline.sql`, `pdl_api.dbml` ↔ `V3__pdl_api_company_enrichment.sql`, `ref.dbml` ↔ `V4__ref_baseline.sql` + `V5__ref_unique_indexes.sql`, `integration.dbml` ↔ `V6__integration_baseline.sql`, `staging.dbml` ↔ `V7__staging_baseline.sql`, plus the later additive migrations). This directory currently holds only this README.

Per-table V_n migrations follow a strict pattern that is easy to template; once the compiler exists it regenerates V_n migrations whenever DBML changes, and hand-edits to files marked `GENERATED FROM DBML` will be overwritten the next time it runs.

The notes below record the compiler design so it can be started from the right place without re-doing the design discussion.

## What it does (intended interface)

Reads `modeling/dbml/*.dbml` (one file per schema today; a recursive glob keeps the door open for splitting large schemas into per-table files) and emits:

1. Flyway migration SQL → `modeling/flyway/migrations/V<n>__*.sql`
2. dbt model stubs → `processing/dbt/models/**/*.sql`
3. dbt `schema.yml` files (column definitions) → `processing/dbt/models/**/schema.yml`
4. ERD renders → `modeling/erd/`

```bash
python -m modeling.scaffolding.dbml_compiler
```

## Design notes

### Why a compiler

- **Removes the dual-edit overhead.** Today every schema change touches DBML + Vn SQL together. Drift is invisible until a migration runs and surprises you.
- **Closes the "DBML is source of truth" promise.** Currently aspirational; with the compiler plus a drift check (future), it becomes real.
- **Most valuable for `integration` + `ref`** — dozens of tables share patterns (timestamp columns, surrogate-id conventions, FK naming). Hand-writing each table twice is error-prone.
- **Validates the toolchain on small cases first** — the hand-authored `catalog.dbml` / `raw.dbml` migrations serve as golden-file targets to validate against before tackling integration.

### Compiler options

**Minimal compiler** — Flyway DDL only:
- Read `modeling/dbml/**/*.dbml` recursively.
- For each `Table`: emit `CREATE SCHEMA IF NOT EXISTS …; CREATE TABLE …; CREATE INDEX …;`
- Topological sort tables so foreign keys reference already-created tables.
- Handle CHECK constraints via a directive comment in the DBML (e.g. `// @check status IN ('active', 'inactive', 'merged_into')`) — DBML has no first-class syntax for them.
- Handle expression defaults. `ref`, `integration` and parts of `catalog` / `pdl_api` use backtick defaults (`` default: `now()` ``); `raw`, `staging`, the rest of `catalog` and the newer `pdl_api` cleaner tables leave them out or describe them only in notes. Settle on one convention (backticks, or a `// @default` directive) before generating.
- Emit `COMMENT ON TABLE` and `COMMENT ON COLUMN` from DBML `Note:` blocks.
- Emit one `V<n>__<schema>.sql` per schema, or a combined baseline.
- Validate against the hand-written V1/V2 as references; compiler output must match (or any divergence is documented and accepted).

**Full compiler** — adds the dbt and ERD outputs:
- Generate dbt `schema.yml` with column descriptions from DBML notes.
- Generate dbt model SQL stubs (empty `SELECT` skeletons in the right directory layout).
- Render ERDs via `@dbml/cli` (Node, official) into `modeling/erd/`.
- A drift check (future) that re-runs the compiler and fails if committed Vn SQL doesn't match the regenerated output.

The full compiler can be built incrementally on top of the minimal one.

### Suggested build order

1. Build the **minimal** compiler.
2. Run it against `catalog.dbml` and `raw.dbml`. Diff against the hand-written V1/V2. Fix divergences (or accept and document).
3. Extend to `ref`, `integration`, `pdl_api` and the Flyway-managed `staging` tables.
4. Add the dbt / ERD outputs of the full compiler.

### Layers and what the compiler covers

The layer stack:

```
raw  →  staging  →  ref / integration  →  warehouse (future; not in scope of this project)
          ↑
        pdl_api (API queues + audit)      catalog (identity ledger + run logging)
```

Every schema's table **shape** is Flyway-managed and modeled in DBML: `catalog`, `raw`, `pdl_api`, `staging`, `ref`, `integration`. dbt only **populates** the `staging`, `ref` and `integration` tables (incremental + TRUNCATE pre-hook; `on_schema_change='fail'`), it never creates them.

So the compiler's Flyway-emitting scope is all six schemas. Its dbt-stub-emitting scope covers the `staging`, `ref` and `integration` model files.

### Known design questions to settle when you start

- **CHECK constraint syntax in DBML.** Use `// @check ...` directive comments (proposed), or wait for upstream DBML to add native syntax (none planned).
- **Expression defaults in DBML.** Backticked defaults work in dbdiagram.io but are applied inconsistently across the files today. Pick one convention (see "Compiler options" above).
- **Schema-level concerns.** `CREATE SCHEMA`, schema-level grants, schema-level extensions (`CREATE EXTENSION`) — where do they live in DBML? Probably in a per-schema `_schema.dbml` file with directive comments.
- **Multi-file aggregation order.** When per-table DBML files reference each other via FK, the compiler must read all files before emitting any SQL (so it knows the full reference graph for topological sort).
- **dbt schema.yml format.** dbt's `schema.yml` has its own conventions (model descriptions, column tests). The generator emits structure; engineers add tests by hand. Verify pydbml exposes enough to populate column descriptions.

## Tests

None yet (there is no `tests/` directory). Golden-file tests are future work: given fixed DBML input, the compiler must produce fixed output, and re-running the generator should produce zero diffs unless DBML changed.

## DBML library choice

Currently `pydbml` (Python). Swappable for the official Node `@dbml/cli` later — see [docs/design/02_pipeline_design.md](../../docs/design/02_pipeline_design.md) Section 11. The Python CLI signature is the stable interface; library internals are not.

Hybrid option (revisit later): use `@dbml/cli` for the SQL DDL part (canonical Postgres output) and pydbml for walking the model to generate dbt stubs. Reasoning in `docs/design/02_pipeline_design.md` Section 11.
