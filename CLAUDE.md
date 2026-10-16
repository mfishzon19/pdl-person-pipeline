# PDL Pipeline — Claude Context

Local-only pipeline that ingests PDL Person deliveries, parses them in dbt, calls PDL APIs (company enrichment + company / location / school cleaners), builds the `ref.*` + `integration.*` model, and applies the cleansing routines in [`docs/pdl_data_cleansing/`](docs/pdl_data_cleansing/). Start at [`README.md`](README.md) and [`docs/README.md`](docs/README.md).

## Rules

- **Never push to GitHub** — engineers push manually.
- **Never commit unless explicitly asked.**
- **Never hardcode secrets, API keys, or database credentials** in any file. Use environment variables (a gitignored `.env` locally). The only credentials allowed in the repo are the throwaway local Docker defaults already in `docker-compose.yml`.
- **Never call PDL APIs in tests** — all external calls must be mocked. Tests must run without AWS credentials or network access. The only exception is `processing/pdl_api/tests/test_pdl_smoke.py` (marker `pdl_smoke`), which skips unless `PDL_API_KEY` is set; run the default suite with `-m "not pdl_smoke"` when a key is exported.
- **Never modify DBML in `modeling/dbml/`** without explicit instruction — DBML drives all schema migrations.
- **Never edit an applied versioned migration** (`V<n>__*.sql`) — Flyway checksums it; ship a new `V<n>` instead. Repeatable `R__*.sql` files (functions, permissions) are edited in place. The DBML → Flyway / dbt generator (`modeling/scaffolding/`) is not built, so migrations are written by hand against the DBML.
- **Never remove or rename existing pipeline arguments** (CLI flags, make targets) without explicit instruction — scripts and manual invocations depend on them.
- **README-first for docs-tree changes.** Any change that ADDS, REMOVES, or RENAMES a file in `docs/**` must also update the corresponding subdir `README.md` in the same change — the READMEs are file indexes with one-line descriptions. Content-only edits to an existing file don't require README updates.
- **Docs-first for design-affecting changes.** Any change to DBML, Flyway migrations, dbt model structure, ADRs, or pipeline shape must include the corresponding doc update in the same change (relevant `docs/data_model/*`, `docs/design/*`, `docs/decisions/*`). The docs are the record of what we built — if they're wrong, every downstream decision compounds the error. If a change genuinely has no doc impact (bug fix, test update, cosmetic refactor), say so explicitly.
- **Keep the repo client-neutral.** No client names, people's names, real customer data, or client-specific business rules in code, docs or fixtures. Cleansing input files with real company or person data are supplied locally and never committed.

## Local environment

Full design: [`docs/design/local-dev-design.md`](docs/design/local-dev-design.md).

- **Python**: conda env `pdl_test` — `conda env create -f environment.yml && conda activate pdl_test`.
- **Docker Compose services** (infrastructure only): `postgres` (db / user `pdl_etl`, password `pdl_etl_dev`, `localhost:5432`), `flyway-init` (applies `modeling/flyway/migrations`), `fixture-load` (loads the committed, fully synthetic PDL-shaped sample `infra/local/fixtures/pdl-person-sample-v1.csv.gz`, or a `FIXTURE_URL` override); profile `ingester`: `s3` + `s3-init` (local S3 stand-in: moto server on `localhost:9000`, bucket `pdl-ingest-local`, any credentials, in-memory — re-seeded by `make dev-up-ingester`, no web console). Containers are named `pdl_test_*`.
- **Host-side tools**: the ingester, PDL API callers, dbt, pytest and ruff run on the host in the `pdl_test` env — there are no runner containers.
- **DSN**: `postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl` (`DATABASE_URL` in `.env`, see `.env.example`). dbt reads `DBT_PG_*` via `processing/dbt/profiles.yml`, never `DATABASE_URL`.
- **Make targets**: `make dev-up` (core stack), `make dev-up-ingester` (+ local S3, empty `raw`), `make ingest-pdl` (Finder → Loader → PDL projection), `make dbt-pdl` (`dbt build --select tag:pdl+`), `make dbt-<tag>`, `make pipeline-pdl` (ingest + dbt), `make clean-pdl` / `make enrich-pdl SOURCE_LIST=x MAX_CREDITS=n` (live PDL API; refuse to run without `PDL_API_KEY`), `make test`, `make lint`, `make dev-ps` / `make dev-logs`, `make dev-down` (keep data), `make dev-reset` (wipe volumes), `make help`.
- **Raw load path**: the ingester downloads each delivery file from S3 (or local S3) with boto3 and loads it with a psycopg2 `COPY ... FROM STDIN` into the `raw.*` leaf partition. There is no other load path.

## Schema work — source-of-truth hierarchy

When writing or editing a dbt model (`processing/dbt/models/**`), a Flyway migration (`modeling/flyway/migrations/**`), or a `schema.yml` entry, read sources in this order:

1. **`modeling/dbml/<schema>.dbml`** — destination shape. This is the CONTRACT. Column names, types, nullability, uniqueness, indexes. When you write a dbt SELECT, the column list must match the DBML table block exactly (order, types, names). The DBML always reflects the schema's *current* state.
2. **`docs/data_model/*`** (e.g. `13_person.md` §6 for PDL person) — column-mapping intent. Tells you WHICH source field (`$.path` in raw JSON) populates a given destination column and WHY a column exists. Prose, not contract.
3. **PDL source docs** (docs.peopledatalabs.com) — value semantics. "What does `proficiency: 3` mean?" "What are valid `network` values?"
4. **`modeling/flyway/migrations/V<n>__*.sql`** — derived from DBML. Cross-reference only; **not canonical**. If DBML and a V_n migration disagree on column shape, **DBML wins** — the migration is the bug.
5. **Existing dbt models** (e.g. `pdl_person_experience_parsed.sql`) — patterns to copy, not specs. "Use this as your template" means follow the structure (outer SELECT + JSON_TABLE + NESTED PATH), not "match its output."

**Why this order matters**: `on_schema_change='fail'` enforces that DBML / Flyway DDL / dbt SELECT all agree. If three of them agree and `dbt build` still fails, one of them is wrong; figure out which by reading DBML first.

**The discipline that makes DBML trustworthy**: every DBML edit ships in the same change as the migration that produces the new state. The DBML must never describe a state no migration has produced (and vice versa).

See [docs/design/02 §11](docs/design/02_pipeline_design.md) for the full migration file-scoping convention.

**Layer mechanics:**
- [`docs/design/16_dbt_pipeline_layers.md`](docs/design/16_dbt_pipeline_layers.md) — source-agnostic dbt layer model (raw / staging / ref / integration / catalog), naming conventions, DAG ordering, "siblings read raw" design choice.
- [`docs/requirements/01_pipeline_requirements.md §2`](docs/requirements/01_pipeline_requirements.md) — refresh patterns per layer (stateless rebuild vs stateful append-only).
- [`docs/decisions/0005-ref-population-layer.md`](docs/decisions/0005-ref-population-layer.md) — ref tables are populated by their own dbt layer in `models/ref/`, not by staging.
- [`docs/design/15_pdl_staging_design.md`](docs/design/15_pdl_staging_design.md) — PDL-specific staging design.
- [`docs/design/21_cleansing_layer_design.md`](docs/design/21_cleansing_layer_design.md) + [`docs/pdl_data_cleansing/`](docs/pdl_data_cleansing/) — cleansing layer design and the routines it implements.
