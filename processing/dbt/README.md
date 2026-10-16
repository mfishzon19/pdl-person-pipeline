# processing/dbt/

dbt Core project. Reads from `raw.*`, `catalog.*` and `pdl_api.*` (sources) and writes `staging.*`, `ref.*` and `integration.*`. Every target table is **Flyway-owned for DDL** (shape authored in `modeling/dbml/`); dbt only populates it, via `materialized='incremental'` per [docs/design/02 §11](../../docs/design/02_pipeline_design.md).

## Setup

Prerequisite: the `pdl_test` conda env is active and has dbt installed via `environment.yml` (see repo root [README](../../README.md) for env setup).

```bash
cd processing/dbt
cp profiles.yml.example profiles.yml   # first time only — gitignored
dbt debug                              # verify connectivity to local Docker postgres
dbt build                              # build all models
```

`profiles.yml.example` (profile `pdl_etl`, target `local`) points at local Docker: `localhost:5432`, database `pdl_etl`, user `pdl_etl`, password from `DBT_PG_PASSWORD` (default `pdl_etl_dev` — same credentials as `docker-compose.yml`). Override host/port/user/db with `DBT_PG_HOST` / `DBT_PG_PORT` / `DBT_PG_USER` / `DBT_PG_DBNAME`.

## Layout

```
dbt_project.yml
profiles.yml.example         template; real profiles.yml is gitignored
models/
  sources.yml                declares raw.* + catalog.* + pdl_api.* sources (Flyway-owned tables)
  staging/pdl_person/        PDL person: parsed → unique
  staging/pdl_api/           PDL Company Enrichment responses (parsed)
  ref/                       loader-discovered reference vocabularies
  integration/               conformed person, company, school, experience + junctions
tests/                       singular tests (one bespoke SQL each, expected to return zero rows)
macros/                      shared SQL helpers, FK drop/recreate hooks, schema-name override
```

## Selective rebuilds

PDL person staging models are tagged `pdl` so a new delivery can run a partial rebuild:

```bash
dbt build --select tag:pdl+      # PDL staging + downstream ref + integration
```

Tag conventions live in `dbt_project.yml`. `ref` and `integration` models are untagged and are picked up by the `+` (descendants) selector.

## Tests

Two kinds:

- **Generic tests** in `models/<...>/schema.yml` (`unique`, `not_null`, `accepted_values`, `relationships`, plus `dbt_utils` tests such as `unique_combination_of_columns`).
- **Singular tests** in `tests/` — one bespoke SQL each, expected to return zero rows.

Run all dbt tests:
```bash
dbt test
```

## Local testing with PDL data

Everything runs against the local Docker Postgres (`make dev-up`; `make dev-reset` to rebuild from an empty volume). Two options, in order of speed-vs-realism:

### 1. Empty build (fastest — validates SQL only)

Confirms that migrations apply cleanly, dbt model SQL compiles, and tests are wired correctly — without any data variability getting in the way.

```bash
make dev-reset                         # fresh Postgres + flyway migrate
cd processing/dbt
dbt build --profiles-dir .
# Expect: models build with 0 rows; tests pass trivially. Any failure here
# = SQL bug; fix before adding data.
```

### 2. With PDL rows

Load data into `raw.pdl_person` — either the sanitized fixture (`make dev-up` loads it directly; `make dev-up-ingester` + `make ingest-pdl` loads it through the ingester) or a real delivery via `python -m processing.s3_ingester.run ...` — then rebuild:

```bash
cd processing/dbt
dbt build --profiles-dir . --select tag:pdl+
# Failures here that the empty build didn't show usually mean an unexpected
# PDL data shape. Adjust DBML / migration / dbt model accordingly.
```

## Conventions

- **Staging / integration / ref models** materialized as **`incremental`** with `incremental_strategy='append'` + `pre_hook='TRUNCATE TABLE {{ this }} RESTART IDENTITY CASCADE'` + `on_schema_change='fail'` (per [docs/design/02 §11](../../docs/design/02_pipeline_design.md)). This is the stateless full-rebuild pattern: TRUNCATE clears the Flyway-owned table, then bulk INSERT from upstream. `materialized='table'` is **forbidden** in DBML-managed schemas because it would drop and recreate the Flyway-created table, bypassing the DDL contract. Override an individual cheap model to `view` via `{{ config(materialized='view') }}` only when re-parsing on every query is acceptable.
- **`ref.*` populations** are loader-discovered: each `ref` model derives a DISTINCT vocabulary from staging (e.g. `ref.country` / `ref.state_province` / `ref.city` / `ref.metro` / `ref.location` from parsed addresses) and rebuilds it with the same TRUNCATE + append pattern; surrogate ids are computed in SQL (ADR-0008). dbt's DAG handles the order (country → state_province → city → metro → location).
- **`schema.yml` files are hand-authored today.** Once `modeling/scaffolding/dbml_compiler` ships, schema.yml column definitions will be regenerated from DBML; for now they're hand-edited alongside model SELECT logic.
- **Schema-name override.** A `generate_schema_name` macro in `macros/` makes `+schema: staging` resolve to bare `staging` (not `<target>_staging`), required so dbt writes to the Flyway-managed `integration` schema directly rather than `<target>_integration`.
