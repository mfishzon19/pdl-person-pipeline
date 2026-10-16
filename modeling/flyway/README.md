# modeling/flyway/

Flyway migrations and runtime config.

## Directory contents

- `flyway.conf` — Flyway runtime config (local Postgres URL `localhost:5432/pdl_etl`, user `pdl_etl`, schemas to manage, baseline behavior).
- `migrations/V<n>__*.sql` — forward-only versioned migrations, `V1`–`V36`. Version numbers have gaps (V18 and V29–V34 are unused); Flyway doesn't require contiguous versions.
  - `V1`–`V7` — per-schema baselines: `catalog`, `raw`, `pdl_api` (company cleaner + enrichment), `ref` (+ `V5` COALESCE unique-index sidecar), `integration`, `staging`.
  - `V8`–`V27` — incremental staging / ref / integration / catalog changes (year-only date columns, new `_parsed` / `_unique` tables, dropped unsourced tables and columns, dbt-computed surrogate ids, the `catalog._dropped_fks` FK-tracking table, index tuning, inline address scalars).
  - `V28` — company enrichment schema (`staging.pdl_api_company_*`, `ref.pdl_relationship`, `integration.company` rebuild, `integration.company_affiliation`).
  - `V35`, `V36` — `pdl_api` location and school cleaners.
- `migrations/R__*.sql` — repeatable, hand-authored migrations:
  - `R__function_project_pdl_deltas.sql` — projects raw PDL delta files into the catalog ledger.
  - `R__permissions.sql` — confirms the migrating role (`pdl_etl`) owns every managed schema.
  - `R__roles.sql` — creates the NOLOGIN read-only bundle `pdl_etl_reader` (USAGE + SELECT on all data schemas).

## Managed schemas

`catalog`, `raw`, `pdl_api`, `ref`, `integration`, `staging`.

## Apply migrations locally

The docker-compose `flyway-init` service runs `flyway migrate` automatically on `make dev-up`. To run it by hand against the local Postgres:

```bash
flyway -configFiles=modeling/flyway/flyway.conf migrate
```

To rebuild from scratch (drops the local volume, re-runs every migration): `make dev-reset`.

## Conventions

- **Forward-only.** No down migrations. Rollbacks are themselves forward migrations.
- **Hand-authored migrations** (e.g. Postgres function definitions): mark the file header explicitly.
- **Filename**: `V<n>__<schema>_<purpose>.sql` (versioned) or `R__<purpose>.sql` (repeatable). Schema name always first after `__`.
- **File scope**:
  - Each schema gets exactly one baseline migration (`V<n>__<schema>_baseline.sql` or `V<n>__<schema>_<feature>.sql`).
  - Subsequent additions = one new V_n per coherent unit (new table, new feature, ALTER, sidecar).
  - DBML always reflects current state; migrations are how-we-got-there.
- **Mutability**: this project is local-only and rebuilds from an empty database, so historical migrations may be edited when needed (checksums change; run `make dev-reset`). Prefer a new V_n for ordinary schema changes.

## What lives here

- Tables in `catalog.*`, `raw.*`, `pdl_api.*`, `ref.*`, `staging.*`, `integration.*`
- Postgres functions (`project_pdl_deltas`)
- Indexes, constraints, partitioning structure
- Schemas themselves (`CREATE SCHEMA` statements)
- Roles and ownership (`R__roles.sql`, `R__permissions.sql`)

dbt-managed table **content** is not Flyway-managed, but the table **schema** is.

Raw files are loaded by the Python ingester (`processing/s3_ingester/`) with `COPY ... FROM STDIN`; there is no SQL-side S3 loader function.
