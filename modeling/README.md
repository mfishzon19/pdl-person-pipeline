# modeling/

Data-modeling layer and the schema source of truth (see [docs/design/02_pipeline_design.md](../docs/design/02_pipeline_design.md) §11, "Data Modeling and Schema Migration Strategy").

## Subdirectories

- [`dbml/`](dbml/) — hand-authored DBML, one file per Postgres schema (`catalog`, `raw`, `pdl_api`, `ref`, `staging`, `integration`). The contract for table shape. Also holds `combine.sh` and `scopes/` for rendering review-sized ERDs.
- [`flyway/`](flyway/) — Flyway config and the migrations that build those schemas (`V1`–`V36`, with gaps, plus repeatable `R__*.sql`). Forward-only.
- [`scaffolding/`](scaffolding/) — design notes for a planned DBML → Flyway / dbt compiler. **Not implemented yet**; the directory holds only its README.

## Authoring flow today

DBML and migrations are both hand-authored and kept in sync by hand:

1. Edit the table in `dbml/<schema>.dbml`.
2. Write a new `flyway/migrations/V<n>__<schema>_<purpose>.sql` that takes the database from the old shape to the new one. DBML always describes the current state; migrations describe how it got there.
3. Update the matching dbt model and `schema.yml` under [`../processing/dbt/models/`](../processing/dbt/models/) so its SELECT matches the DBML column list (`on_schema_change='fail'` rejects any drift).
4. Apply locally: `make dev-up` (or `make dev-reset` to rebuild from an empty database), then run dbt.

Ship the DBML edit, the migration and the dbt change together.

## Target flow (once the compiler exists)

```
dbml/*.dbml  ──>  scaffolding compiler  ──>  flyway/migrations/V<n>__*.sql
                                        ──>  ../processing/dbt/models/**/*.sql      (stubs)
                                        ──>  ../processing/dbt/models/**/schema.yml
                                        ──>  erd/                                    (renders)
```

See [`scaffolding/README.md`](scaffolding/README.md) for the intended interface and build order.

## Hand-authored exceptions

Some objects can't be expressed in DBML and will stay hand-authored even after the compiler lands: Postgres functions (`R__function_project_pdl_deltas.sql`), roles and ownership (`R__roles.sql`, `R__permissions.sql`), and sidecar migrations for expression / partial / GIN indexes, partitioning, sequences and generated columns. Each carries a header saying so. Details: [`dbml/README.md`](dbml/README.md#what-dbml-cant-express--sidecar-hand-authored-migrations).
