# modeling/dbml/

Hand-authored DBML files. **The only place to change the data schema shape**
for schemas modeled in DBML.

## Files

- `catalog.dbml` — identity ledger + run logging ([docs/design/02 §9–§10](../../docs/design/02_pipeline_design.md))
- `raw.dbml` — raw landing tables for PDL Person + PDL delta files (docs/design/02 §5)
- `pdl_api.dbml` — operational state for the generic PDL API caller: company cleaner + enrichment, location cleaner and school cleaner queues and audit tables. See [docs/design/18](../../docs/design/18_pdl_api_generic_caller.md).
- `ref.dbml` — canonical reference tables: place hierarchy, industry, job-title hierarchy, seniority, personal-attribute tables, PDL company relationship vocabulary ([docs/data_model/10](../../docs/data_model/10_reference_tables.md), [12](../../docs/data_model/12_location.md), [13 §5](../../docs/data_model/13_person.md))
- `staging.dbml` — per-source staging tables (parsed → unique → staged pattern; docs/design/02 §8). dbt models populate them via incremental + truncate; the DDL is Flyway-owned, same as integration.
- `integration.dbml` — conformed entities: person, company, school, experience, person_education, company_affiliation + all junctions ([docs/data_model/08](../../docs/data_model/08_company.md), [12 §4.7](../../docs/data_model/12_location.md), [13](../../docs/data_model/13_person.md))
- `combine.sh` + [`scopes/`](scopes/README.md) — tooling that concatenates the per-schema files (or a named subset of tables) into one DBML document for dbdiagram.io / `dbml-renderer`.

The `warehouse` schema is not in scope of this project (future work); there is no `warehouse.dbml`.

## Schemas not modeled in DBML

- **Functions** (`R__function_*.sql`), **permissions** (`R__permissions.sql`,
  `R__roles.sql`), **views** (`R__view_*.sql` when they land), **seed data**
  (`R__seed_*.sql` when seeding migrations land) — DBML cannot express any of
  these; all hand-authored.

## Conventions

- **One DBML file per Postgres schema** (catalog / raw / pdl_api / ref /
  staging / integration). The DBML file always reflects the schema's
  *current* state; Flyway migrations are how-we-got-there.
- All columns, types, nullability, indexes, and `Note` comments live in DBML
  for the schemas above.
- Cross-schema FKs (e.g. `integration.person.location_id → ref.location.id`)
  declared inline via DBML `ref:` syntax.
- **Editing rule**: every DBML change ships in the same change as the migration
  that produces the new state (a new `V<n>__<schema>_<purpose>.sql` for
  additive changes; an `ALTER` migration for column changes). The DBML must
  never describe a state no migration has produced.
- After edits: write the matching migration and dbt change by hand. (Once
  the planned compiler exists, `python -m modeling.scaffolding.dbml_compiler`
  will regenerate them; it does not exist yet.)

See [docs/design/02 §11](../../docs/design/02_pipeline_design.md) for the migration
file-scoping convention (baseline + N additions per schema, plus the
`_baseline` filename suffix).

## What DBML can't express — sidecar hand-authored migrations

DBML covers tables / columns / types / `NOT NULL` / defaults / basic FKs /
basic indexes / table+column comments. It does **not** cover:

- Views, materialized views → `R__view_*.sql`
- Triggers / trigger functions / PL/pgSQL → `R__function_*.sql`
- `COALESCE(...)`-based UNIQUE indexes (used on `ref.city`, `ref.location`)
  → `V5__ref_unique_indexes.sql` (sidecar to V4)
- Trigram / GIN / GIST / BRIN indexes (e.g. a future trigram index on
  `integration.experience.title`) → `V<n>__<schema>_<feature>.sql` sidecar
- Partial indexes (`WHERE status = 'pending'`) — e.g. the `pdl_api.*_input_list`
  pending-queue indexes live in `V3` / `V35` / `V36` alongside the tables they
  index; the staging address partials live in `V22`
- Expression / DESC-ordered indexes (e.g. the `V19` staging dedup covering
  indexes)
- Partitioning (raw tables — `raw.pdl_person` is partitioned by file index
  per docs/design/02 §5)
- Row-level security, foreign tables, deferrable constraints
- Sequences (e.g. `pdl_api.company_enrichment_batch_seq`)
- GENERATED columns (e.g. `pdl_api.*.pdl_company_id` STORED GENERATED from
  `response_json->>'id'`)
- CHECK constraints with complex predicates

Today every migration is hand-written; the baselines and sidecars that will
stay hand-authored after the compiler lands carry a `HAND-AUTHORED` banner.
Objects they add are documented in the DBML file's table `Note` (e.g. "UNIQUE
on (...) created by hand-authored sidecar migration — DBML cannot express
COALESCE in indexes").

## Status of the scaffolding compiler

**The compiler doesn't exist yet.** `modeling/scaffolding/` holds only its
design README. Until it ships, the DBML files are the source-of-truth spec
and the Flyway migrations (`V1`–`V36`, with gaps) are hand-authored against
them. Once the compiler lands, the baselines (`V1__catalog_baseline.sql`,
`V2__raw_baseline.sql`, …) can be regenerated from the DBML and diffed
against the hand-written versions, and later migrations generated directly.
The project rebuilds from an empty local database (`make dev-reset`), so
changed checksums need no `flyway repair`.

## Editing tips

- DBML reference: <https://dbml.dbdiagram.io/docs>
- Visualize: paste DBML into <https://dbdiagram.io> for a live ERD render,
  e.g. `./combine.sh --scope core | pbcopy` (see [`scopes/README.md`](scopes/README.md)).
