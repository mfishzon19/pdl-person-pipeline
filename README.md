# PDL Pipeline

A local data pipeline for **People Data Labs (PDL)** Person data. It ingests PDL's monthly bulk deliveries from S3, parses the nested JSON with dbt into a normalized relational model, resolves and enriches companies, locations and schools through the PDL API, and tracks PDL's identity events (merges, deletions, opt-outs) across deliveries. A set of data-cleansing routines is prototyped on top.

Everything runs on a laptop: Postgres, Flyway and an optional MinIO (S3 stand-in) in Docker Compose; the Python ingester, the PDL API callers and dbt in a conda env.

## How it works

```
 PDL Person delivery (S3 or local MinIO)
   {date}/data/part-*.csv.gz  +  delta_data/{MERGED,DELETED,OPTED_OUT}_RECORDS_*  +  COMPLETED
        │
        │ 1. INGEST     processing/s3_ingester                    make ingest-pdl
        │    Finder → Loader (boto3 + COPY FROM STDIN) → delta projection
        ▼
   raw.pdl_person, raw.pdl_*_records            catalog.* (run / file log, identity ledger)
        │
        │ 2. PARSE      dbt staging (JSON_TABLE)                   make dbt-pdl
        ▼
   staging.pdl_person_*_parsed → *_unique  (deduped, merged ids resolved)
        │
        │ 3. PDL API    processing/pdl_api                         make clean-pdl / enrich-pdl
        │    company enrichment (bulk, billed) + company / location / school cleaners
        ▼
   pdl_api.*_input_list (queues) → pdl_api.*_call (audit) → staging.pdl_api_company_parsed
        │
        │ 4. MODEL      dbt ref + integration                      make dbt-pdl
        ▼
   ref.*          place hierarchy, industry, job titles, seniority, skills, ...
   integration.*  person, company, company_affiliation, school, experience, education, junctions
        │
        │ 5. CLEANSE    docs/pdl_data_cleansing  (SQL, run by hand)
        ▼
   name / title / company / location / LinkedIn normalization, broken-company filter,
   person / experience / education dedup, degree families, school rollup, company hierarchy
```

Steps 1, 2 and 4 are one command (`make pipeline-pdl`). Step 3 spends PDL credits and only runs when asked. Step 5 is a set of SQL prototypes with a [design](docs/design/21_cleansing_layer_design.md) for moving them into dbt.

## Design highlights

- **Stateless content, stateful identity.** `staging`, `ref` and `integration` are truncated and rebuilt from the latest snapshot on every run. Only two things persist across runs: the identity ledger in `catalog` (PDL id aliases, deactivations, merge events) and the PDL API cache in `pdl_api`. Recovery from bad content is a rebuild. ([design/02 §2](docs/design/02_pipeline_design.md), [ADR-0007](docs/decisions/0007-integration-current-state-ledger-history.md))
- **DBML is the schema contract.** Each schema is defined once in `modeling/dbml/`, created by forward-only Flyway migrations, and populated by dbt with `on_schema_change='fail'`, so DBML, DDL and dbt SELECTs cannot drift apart silently. ([ADR-0001](docs/decisions/0001-dbml-owns-table-shape-across-layers.md))
- **Config-driven, atomic ingestion.** Raw tables are LIST-partitioned one leaf per source file. Each file is a TRUNCATE + COPY in one transaction together with its catalog status row, so a re-run is idempotent. A new file group is a YAML edit. ([design/02 §5–6](docs/design/02_pipeline_design.md))
- **Merge-aware staging.** PDL re-merges person ids across deliveries. Staging walks multi-hop alias chains to the terminal id and collapses two-member cycles deterministically. ([design/15](docs/design/15_pdl_staging_design.md))
- **A PDL API caller that never pays twice.** Queue tables with `SKIP LOCKED` claims, one append-only audit row per call, per-endpoint rate limits, daily / monthly credit caps, and a bulk crash-recovery path that replays saved responses instead of calling (and billing) again. ([design/18](docs/design/18_pdl_api_generic_caller.md))
- **Bulk-load performance.** Staging drops and rebuilds its indexes around each INSERT; `ref` / `integration` FKs are dropped before a dbt run and recreated `NOT VALID` after, which removes `TRUNCATE ... CASCADE` deadlocks under `--threads 4`. dbt `relationships` tests are the integrity check. ([ADR-0003](docs/decisions/0003-staging-bulk-load-pattern-1.md), [ADR-0009](docs/decisions/0009-fk-constraint-drop-recreate-for-rebuild.md))

Known gaps are listed in [design/02 §12](docs/design/02_pipeline_design.md#12-open-items): reactivation detection and the stable internal person id (`catalog.person_key_map`) are designed but not built, and the cleansing routines are not yet dbt models.

## Quickstart

Prerequisites: Docker (Docker Desktop or Colima, with the `docker compose` plugin), Conda (Miniconda), `make`.

```bash
# One-time
conda env create -f environment.yml
cp .env.example .env                                              # local defaults; add PDL_API_KEY only to call PDL
cp processing/dbt/profiles.yml.example processing/dbt/profiles.yml

# Each session
conda activate pdl_test
set -a; source .env; set +a

make dev-up            # Postgres + Flyway migrations + fixture load into raw.pdl_person
make dbt-pdl           # steps 2 + 4: dbt build --select tag:pdl+

# Or exercise the real ingester against MinIO
make dev-up-ingester   # + MinIO with the fixture uploaded as a delivery; raw.* left empty
make pipeline-pdl      # ingest-pdl (step 1) + dbt-pdl
```

**Fixture.** The repo ships a small, **fully synthetic** PDL Person sample at `infra/local/fixtures/pdl-person-sample-v1.csv.gz` (~200 made-up people, fictional companies and schools on `.example` domains, real public geography), so `make dev-up` + `make dbt-pdl` work out of the box with no configuration. It is not PDL data; it only mimics the PDL record shape, and `infra/local/scripts/generate-sample-fixture.py` regenerates it deterministically. To use your own sample instead, set `FIXTURE_URL` (HTTPS `.csv.gz`) or drop the file at `infra/local/fixtures-cache/pdl-person-sample-v1.csv.gz`; the loader prefers the cache, then `FIXTURE_URL`, then the committed sample (run `make dev-reset` to switch). `infra/local/scripts/sanitize-pdl-fixture.py` turns a delivery file you are licensed to use into such a sample by replacing PII with fake values while keeping the record shape.

**PDL API (step 3)** needs `PDL_API_KEY` and spends credits, so it never runs automatically: `make clean-pdl` drains the cleaner queues, `make enrich-pdl SOURCE_LIST=x MAX_CREDITS=n` runs a capped enrichment. See [`processing/pdl_api/README.md`](processing/pdl_api/README.md). **Cleansing (step 5)** routines run by hand with `psql -f`; see [`docs/pdl_data_cleansing/README.md`](docs/pdl_data_cleansing/README.md).

Connect any Postgres client to `postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl` (a pgAdmin server definition is in `infra/local/pgadmin/local-server.json`).

### Make targets

| Target | What it does |
|---|---|
| `make dev-up` | Start Postgres, apply Flyway migrations, load the fixture into `raw.pdl_person` |
| `make dev-up-ingester` | Same, but leave `raw` empty and start MinIO (bucket `pdl-ingest-local`) seeded with the fixture as a delivery |
| `make ingest-pdl` | Run the ingester against MinIO (`DELIVERY_DATE=yyyy_mm_dd` to override) |
| `make dbt-pdl` | `dbt build --select tag:pdl+` — PDL staging and everything downstream |
| `make dbt-integration`, `make dbt-<tag>` | Build any dbt tag and its descendants |
| `make pipeline-pdl` | `ingest-pdl` then `dbt-pdl` |
| `make clean-pdl` | Live PDL cleaners: drain the company, location and school queues (`PDL_RPM=N` optional). Needs `PDL_API_KEY`. |
| `make enrich-pdl SOURCE_LIST=x MAX_CREDITS=n` | Live PDL company enrichment with a credit cap. Needs `PDL_API_KEY`. |
| `make test` / `make lint` | pytest / ruff |
| `make dev-ps` / `make dev-logs` | Container status / logs |
| `make dev-down` | Stop containers, keep data |
| `make dev-reset` | Stop containers and wipe all volumes and the fixture cache |
| `make help` | List targets |

Environment details (services, env vars, workflows): [`docs/design/local-dev-design.md`](docs/design/local-dev-design.md).

### Tests

```bash
make test                               # all pytest suites; DB integration tests skip without DATABASE_URL
pytest -m pdl_smoke processing/pdl_api  # live PDL smoke test (needs PDL_API_KEY; free cleaner calls only)
```

PDL and S3 are mocked in every unit and integration test. The live smoke tests in `processing/pdl_api/tests/test_pdl_smoke.py` skip unless `PDL_API_KEY` is set; the marker is not excluded by default, so run `pytest -m "not pdl_smoke"` if your shell has a key exported. dbt tests (`schema.yml` generic tests plus singular tests in `processing/dbt/tests/`) run as part of `make dbt-pdl`. Test plan: [`docs/design/07_test_plan.md`](docs/design/07_test_plan.md).

## Repository layout

```
.
├── docs/                       Requirements, design, data model, ADRs, cleansing routines
├── modeling/                   Schema source of truth
│   ├── dbml/                   Hand-authored DBML, one file per schema (raw, catalog, pdl_api, staging, ref, integration)
│   ├── flyway/                 Versioned + repeatable migrations, flyway.conf
│   └── scaffolding/            Placeholder for the planned DBML → Flyway / dbt generator
├── processing/                 Code that moves and transforms data
│   ├── s3_ingester/            Step 1: Finder → Loader → per-file COPY → PDL delta projection; per-source YAML configs
│   ├── pdl_api/                Step 3: PDL API callers (company enrichment, company / location / school cleaners)
│   ├── common/                 Shared helpers: Postgres, S3, PDL HTTP client, delivery preflight checks, logging
│   ├── dbt/                    Steps 2 + 4: dbt project (staging → ref → integration)
│   └── tests/                  Cross-component tests
├── infra/local/                Compose helper scripts, committed synthetic fixture, fixture cache, Postgres init, pgAdmin server definition
├── docker-compose.yml          postgres, flyway-init, fixture-load; profile `ingester`: minio, minio-init
├── Makefile                    Local entry points
├── environment.yml             Conda env `pdl_test`
├── pyproject.toml              ruff / pytest / sqlfluff config
├── .env.example                Local environment variables template
└── CLAUDE.md                   Project rules for AI-assisted work
```

`docs/`, `modeling/`, `processing/` and most of their subdirectories have their own README.

## Documentation

Start with [`docs/README.md`](docs/README.md), which maps each pipeline step to its docs. Key entry points:

- [Pipeline requirements](docs/requirements/01_pipeline_requirements.md) and [pipeline design](docs/design/02_pipeline_design.md)
- [PDL staging design](docs/design/15_pdl_staging_design.md) and [dbt layers](docs/design/16_dbt_pipeline_layers.md)
- [PDL API caller](docs/design/18_pdl_api_generic_caller.md)
- [Data model](docs/data_model/README.md): person, company, location, reference tables
- [Cleansing layer design](docs/design/21_cleansing_layer_design.md) and [cleansing routines](docs/pdl_data_cleansing/README.md)
- [Architecture decisions](docs/decisions/README.md)

## Making a schema change

1. Edit DBML in [`modeling/dbml/`](modeling/dbml/).
2. Write the matching `V<n>__*.sql` migration in [`modeling/flyway/migrations/`](modeling/flyway/migrations/) (migrations are hand-authored against the DBML; the generator is not built).
3. Update the dbt model(s) so their column lists match the DBML.
4. Update the docs (`docs/data_model/*`, design docs, ADRs) in the same change.
5. `docker compose up flyway-init` to apply just the new migration, or `make dev-reset && make dev-up` to apply everything from scratch; then `make dbt-pdl`.

Migrations are forward-only; a rollback is another forward migration. See [CLAUDE.md](CLAUDE.md) for the source-of-truth order and [design/02 §11](docs/design/02_pipeline_design.md) for the migration file-scoping convention.

## Adding a new source

1. Author DBML (and a migration) for the source's raw and staging tables.
2. Add `processing/s3_ingester/configs/<source>.yaml` — the ingester is config-driven, no framework changes.
3. If the source has post-load semantics (like PDL's delta files → identity ledger), add a hand-written repeatable migration `R__function_project_<source>.sql` and a post-load hook in `run.py`.
4. Add the dbt staging models and tag them.

## Conventions

- **Secrets**: environment variables only (`.env` is gitignored). The only credentials in the repo are the throwaway local Docker defaults.
- **Tests**: no network, AWS or PDL access by default; external calls are mocked.
- **Migrations**: forward-only.
- **Lint**: `ruff` for Python (`make lint`); `sqlfluff` is configured for dbt SQL.
