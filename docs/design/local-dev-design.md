# Local Environment — Design

The pipeline runs entirely on a laptop. Infrastructure — Postgres, migrations, a sample PDL delivery and an optional local S3 stand-in (moto server, `s3` service) — runs in `docker compose`; pipeline code (the ingester, dbt, the PDL API callers, pytest, ruff) runs on the host in the `pdl_test` conda env. A handful of `make` targets drive both. This doc is the canonical description of that environment — what each service does, how bring-up works, and how the pipeline is run against it.

Source files: [`docker-compose.yml`](../../docker-compose.yml), [`Makefile`](../../Makefile), [`environment.yml`](../../environment.yml), [`.env.example`](../../.env.example), `infra/local/` (Postgres init script, compose helper scripts, committed synthetic fixture, fixture cache, pgAdmin import file).

## 1. Goals + non-goals

### Goals

1. **Minutes from clone to first dbt build.** `make dev-up` brings up a migrated database with sample PDL data; `make dbt-pdl` builds the models against it.
2. **Realistic fixture data.** A committed, fully synthetic PDL-Person-shaped sample is loaded into `raw.pdl_person` automatically (no configuration needed), so dbt models build real-shaped rows, not zero.
3. **The real ingester, end to end.** With the `ingester` profile, the same `processing.s3_ingester` code that reads real PDL deliveries from S3 reads a fixture delivery from local S3 and loads it into `raw.*`, writing every catalog ledger row along the way.
4. **Lean by default.** The default bring-up is just Postgres; the `ingester` profile adds local S3 only when you need it.
5. **No database GUI container.** Postgres is published on `localhost:5432`; use any host client (pgAdmin, psql, DBeaver). An importable pgAdmin server profile is provided.

### Non-goals

1. **No orchestration service.** Pipeline steps are plain CLIs and `make` targets, run by hand.
2. **No secrets service.** Secrets come from environment variables — a gitignored `.env` locally (`DATABASE_URL`, `PDL_API_KEY`, …).
3. **No PDL mock service.** Tests mock every PDL call in-process; the opt-in live smoke test (`pytest -m pdl_smoke`) is the only thing that reaches PDL.

## 2. Architecture overview

```mermaid
flowchart TB
    classDef core fill:#fde2c2,stroke:#c97a1f,color:#4a2a08,font-weight:bold
    classDef profile fill:#e8d4f4,stroke:#8a52c9,color:#2a1e3a
    classDef oneshot fill:#fff3a8,stroke:#a88a1f,color:#4a3a08
    classDef host fill:#d4f4dd,stroke:#3c8a52,color:#1e3a2a

    subgraph CORE["core (no profile flag)"]
        PG["<b>postgres</b> — pdl_test_postgres<br/>postgres:18.3, localhost:5432<br/>db / user pdl_etl, pw pdl_etl_dev"]:::core
        FLYWAY["<b>flyway-init</b> (one-shot)<br/>flyway migrate<br/>modeling/flyway/migrations"]:::oneshot
        SEED["<b>fixture-load</b> (one-shot)<br/>cache / fetch fixture<br/>COPY into raw.pdl_person"]:::oneshot
    end

    subgraph INGEST["profile: ingester"]
        S3["<b>s3</b> — pdl_test_s3<br/>moto server, in-memory<br/>S3 API localhost:9000"]:::profile
        S3_INIT["<b>s3-init</b> (one-shot)<br/>bucket pdl-ingest-local<br/>+ fixture delivery"]:::oneshot
    end

    PG --> FLYWAY --> SEED
    SEED -.->|populates| PG
    S3 --> S3_INIT

    HOST["<b>Host</b> — conda env pdl_test<br/>ingester, dbt, PDL API callers, pytest, ruff<br/>make ingest-pdl / dbt-pdl / pipeline-pdl<br/>host DB client → localhost:5432"]:::host
    HOST -.->|DATABASE_URL / DBT_PG_* → localhost:5432| PG
    HOST -.->|AWS_ENDPOINT_URL=http://localhost:9000| S3
```

Containers hold state (database, object store) and run one-shot setup; all pipeline code runs on the host and reaches them on `localhost`.

## 3. Service plan

All container names are prefixed `pdl_test_`.

### 3.1 `postgres` — core

- Image `postgres:18.3` (pinned; a major-version bump needs `make dev-reset` or `pg_upgrade` on an existing volume).
- `POSTGRES_USER=pdl_etl`, `POSTGRES_PASSWORD=pdl_etl_dev`, `POSTGRES_DB=pdl_etl`; published on `localhost:5432`. DSN: `postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl` (inside the compose network the host is `postgres`).
- Named volume `postgres_data` mounted at `/var/lib/postgresql` (the postgres:18 data-directory layout), so data survives `make dev-down`.
- `infra/local/postgres/init.sql` runs on first boot (before Flyway) and installs the extensions the schema needs: `pgcrypto` (for `gen_random_uuid()` defaults in `catalog.*`) and `pg_trgm`. No S3 extension — loads are local `COPY` (see §4).
- Healthcheck: `pg_isready -U pdl_etl -d pdl_etl`.

These are throwaway local defaults; they're the only credentials allowed in the repo.

### 3.2 `flyway-init` — core, one-shot

- Image `flyway/flyway:12.6.1`; waits for `postgres` healthy.
- `flyway migrate` against `jdbc:postgresql://postgres:5432/pdl_etl` with schemas `catalog, raw, pdl_api, ref, integration, staging`, `baselineOnMigrate=true`, `validateMigrationNaming=true`. Migrations are bind-mounted read-only from `modeling/flyway/migrations`.
- Same settings as `modeling/flyway/flyway.conf`, so a host-side `flyway -configFiles=modeling/flyway/flyway.conf migrate` is equivalent.
- Re-run on its own after adding a migration: `docker compose up flyway-init`.

### 3.3 `fixture-load` — core, one-shot

- Runs `infra/local/scripts/fixture-load.sh` in a `postgres:18.3` container (for `psql`); waits for `flyway-init` to complete successfully.
- **Fixture resolution:** cached file `infra/local/fixtures-cache/${FIXTURE_VERSION}.csv.gz` (default `pdl-person-sample-v1`; gitignored) → else download from `FIXTURE_URL` (optional override, no default) → else the committed sample `infra/local/fixtures/${FIXTURE_VERSION}.csv.gz` (bind-mounted read-only at `/fixtures`) → else skip with a notice (migrations still applied; `raw.pdl_person` stays empty). A failed download also falls back to the committed sample. Whatever is used is copied into the cache, where `s3-init` picks it up; the cache wins on later runs until `make dev-reset` clears it.
- **Committed sample:** ~200 **fully synthetic** person records (plus two duplicate-id records) generated by `infra/local/scripts/generate-sample-fixture.py` (stdlib only, fixed seed, byte-for-byte reproducible). Nothing in it comes from PDL: names are random combinations of generic first / last names, companies and schools are fictional with `.example` domains, emails use `example.com`, ids are random base62. Only public geography and PDL's public taxonomy words (roles, levels, industries, sizes) are real. It populates every JSON path the staging models read — top-level scalars, `skills` / `interests` / `location_names` / `regions` / `countries`, `experience[]` (title, levels, company, company location), `education[]` (school, school location, degrees / majors) — and includes the quirks staging handles: `"true"` / `"false"` bool-placeholders on redacted top-level fields, `yyyy` / `yyyy-mm` / `yyyy-mm-dd` dates, missing optional fields, duplicate person / experience / education entries, promotions at one company, company-name variants under separate ids, coarse (country-only) school locations.
- **Own sample:** a fixture is gzipped JSONL, one PDL person per line. `infra/local/scripts/sanitize-pdl-fixture.py` produces one from a licensed delivery file (replaces every PII field with faker values while preserving shape, nesting, list lengths and value-presence distributions); host it at `FIXTURE_URL` or drop it into the cache directory.
- **Load:** `TRUNCATE` + `COPY` into the `raw.pdl_person` leaf partition inside one transaction, so re-runs are idempotent.
- `SKIP_RAW_LOAD=1` caches the fixture without loading it — used by `make dev-up-ingester` so the ingester populates `raw.*` itself.

### 3.4 `s3` — profile `ingester`

**The local S3 stand-in is moto server** — [moto](https://github.com/getmoto/moto), the same library the unit tests use to fake S3, running in server mode in a container. It speaks the S3 API on `localhost:9000` (container port 5000), so `boto3` talks to it unchanged. It is not the ingester — the ingester runs on the host and reads from local S3:

```
Real delivery:  boto3 ──HTTPS──▶ S3                (PDL delivery bucket, AWS_PROFILE credentials)
Local:          boto3 ──HTTP───▶ localhost:9000    (local S3, same layout, AWS_ENDPOINT_URL set)
```

Same Python code on both sides; only `AWS_ENDPOINT_URL`, credentials and the bucket (via the `--source` config) change.

- Image `motoserver/moto:5.1.16`; container `pdl_test_s3`; inside the compose network the endpoint is `http://s3:5000`. Healthcheck: `curl /moto-api/`.
- Accepts any credentials; the Makefile uses `local` / `local`.
- **In-memory, no volume:** restarting the container (or `make dev-down`) clears the bucket; `make dev-up-ingester` re-seeds it.
- No web console. Inspect objects with boto3 or the AWS CLI, e.g. `aws --endpoint-url http://localhost:9000 s3 ls s3://pdl-ingest-local --recursive`.

### 3.5 `s3-init` — profile `ingester`, one-shot

Runs `infra/local/scripts/s3-init.py` with boto3 inside the same moto image, after `s3` is healthy and `fixture-load` has cached the fixture (idempotent):

- Creates bucket **`pdl-ingest-local`**.
- Uploads the cached fixture as a PDL-shaped delivery:
  ```
  s3://pdl-ingest-local/2026_05_22/data/part-00000.csv.gz   ← fixture data
  s3://pdl-ingest-local/2026_05_22/COMPLETED                ← sentinel
  ```
  This matches `processing/s3_ingester/configs/pdl_full_local.yaml` (identical to `pdl_full.yaml` except `bucket: pdl-ingest-local`). Real deliveries also carry a `delta_data/` subtree (merged / deleted / opted-out records); the committed synthetic sample omits it and the Finder treats it as optional.

## 4. Raw load path

There is exactly one way data gets into `raw.*`: the ingester (`processing/s3_ingester`) — **Finder → Loader → PDL projection**:

1. **Finder** lists the delivery prefix in S3 (or local S3), checks the `COMPLETED` sentinel, and records the delivery's files in the catalog ledger.
2. **Loader** downloads each file with boto3, decompresses it, and streams it into the file's `raw` leaf partition with psycopg2 `COPY ... FROM STDIN` (atomic per-file replace).
3. **PDL projection** (`raw.project_pdl_deltas()`) projects the delta files (merged / deleted / opted-out records) into the identity ledger (`catalog.pdl_id_aliases`, `catalog.pdl_inactive`, …).

The ingester is idempotent per delivery via `catalog.ingestion_run` / `catalog.ingestion_file`. `fixture-load` uses the same `COPY` mechanism directly for the default (non-ingester) bring-up. See [`02_pipeline_design.md`](02_pipeline_design.md) for the ingester design and [§10 Catalog logging](02_pipeline_design.md#10-catalog-logging) for the ledger tables.

## 5. Environment setup

### Prerequisites

Docker (with Compose v2), git, and conda (all pipeline code runs on the host).

```bash
conda env create -f environment.yml     # once
conda activate pdl_test

cp .env.example .env                    # once; .env is gitignored
set -a; source .env; set +a             # each shell session

cp processing/dbt/profiles.yml.example processing/dbt/profiles.yml   # once (make dbt-* does this automatically)
```

### Environment variables

| Variable | Used by | Local value |
|---|---|---|
| `DATABASE_URL` | ingester, PDL API callers, `processing.common.db.connect()` | `postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl` |
| `DBT_PG_HOST` / `_PORT` / `_USER` / `_PASSWORD` / `_DBNAME` | dbt `local` target (dbt does **not** read `DATABASE_URL`) | `localhost` / `5432` / `pdl_etl` / `pdl_etl_dev` / `pdl_etl` |
| `AWS_ENDPOINT_URL`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` | boto3 (Finder, Loader) | `http://localhost:9000`, `local`, `local`, `us-east-1` (local S3 accepts any credentials) |
| `PDL_API_KEY` | `processing.common.pdl` (PDL API callers, live smoke test) | unset unless calling PDL |
| `FIXTURE_URL`, `FIXTURE_VERSION` | `fixture-load`, `s3-init` | optional |
| `LOG_LEVEL` | `processing.common.logging_setup` | `INFO` |

**Reading a real PDL delivery** instead of local S3: unset `AWS_ENDPOINT_URL` and the local `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, set `AWS_PROFILE` (or standard AWS credentials) with read access to the delivery bucket, and run the ingester with `--source pdl_full`.

## 6. Make targets

| Target | What it does |
|---|---|
| `make dev-up` | Core stack: `postgres` → wait for ready → `flyway-init` + `fixture-load`. Prints connection details. |
| `make dev-up-ingester` | Core stack with `SKIP_RAW_LOAD=1` (raw stays empty) + `s3` + `s3-init` (re-seeds local S3, which is in-memory). |
| `make ingest-pdl` | Host: `python -m processing.s3_ingester.run --source pdl_full_local --delivery-date $(DELIVERY_DATE) --max-concurrency 2` against local S3 (default `DELIVERY_DATE=2026_05_22`). |
| `make dbt-pdl` | Host: `dbt build --select tag:pdl+` (PDL staging + everything downstream). |
| `make dbt-<tag>` | Pattern rule: `dbt build --select tag:<tag>+` for any tag in `dbt_project.yml`. |
| `make dbt-integration` | Host: `dbt build --select tag:integration+`. |
| `make pipeline-pdl` | `ingest-pdl` then `dbt-pdl`. |
| `make clean-pdl` | Host: drain the company / location / school cleaner queues (live PDL; refuses without `PDL_API_KEY`). |
| `make enrich-pdl` | Host: company enrichment for `SOURCE_LIST` capped at `MAX_CREDITS` (live PDL; refuses without `PDL_API_KEY`). |
| `make dev-ps` / `make dev-logs` | Service status / tail logs across profiles. |
| `make dev-down` | Stop services, keep volumes. |
| `make dev-reset` | Stop services, drop volumes, clear the fixture cache. Run `make dev-up` to start over. |
| `make test` / `make lint` | `pytest` (DB integration tests skip unless `DATABASE_URL` is set) / `ruff check processing`. |
| `make help` | List targets. |

Connection settings are Make variables matching the compose defaults (`PG_USER`, `PG_PASSWORD`, `PG_DB`, `PG_HOST`, `PG_PORT`, `LOCAL_BUCKET`, `DELIVERY_DATE`); override on the command line, e.g. `make ingest-pdl DELIVERY_DATE=2026_06_01`.

## 7. Workflows

### Write or change a dbt model

```bash
make dev-up                    # postgres + migrations + fixture in raw.pdl_person
conda activate pdl_test
# edit processing/dbt/models/staging/pdl_person/pdl_person_education_parsed.sql
cd processing/dbt
dbt build --select pdl_person_education_parsed     # or: make dbt-pdl from the repo root
```
### Test a Flyway migration

```bash
# add modeling/flyway/migrations/V<n>__<name>.sql (+ the matching DBML change)
docker compose up flyway-init        # additive: apply just the new migration
# or
make dev-reset && make dev-up        # from scratch: all migrations + fixture
```

### Run the full ingest chain

```bash
make dev-up-ingester           # local S3 with the fixture delivery; raw.* empty
make pipeline-pdl              # Finder → Loader → projection, then dbt build tag:pdl+
```

Catalog ledger rows, `raw.*` rows and the rebuilt `staging` / `ref` / `integration` tables are all visible in your DB client.

### Call the PDL API

```bash
export PDL_API_KEY=...         # never commit it
make clean-pdl                                   # all three cleaners
make enrich-pdl SOURCE_LIST=x MAX_CREDITS=100   # company enrichment, capped
```

See [`18_pdl_api_generic_caller.md`](18_pdl_api_generic_caller.md). Responses persist in `pdl_api.*` and are picked up on the next `make dbt-pdl`.

### Browse the data

Point any Postgres client at `localhost:5432` (db / user `pdl_etl`, password `pdl_etl_dev`). For pgAdmin, import `infra/local/pgadmin/local-server.json` via *Import/Export Servers*; it prompts for the password on first connect.

## 8. Bring-up sequence

```mermaid
sequenceDiagram
    participant Eng as Engineer
    participant Make as make dev-up
    participant Compose as docker compose
    participant PG as postgres
    participant FW as flyway-init
    participant FX as fixture-load

    Eng->>Make: make dev-up
    Make->>Compose: up -d postgres
    Compose->>PG: start (init.sql on first boot)
    Make->>PG: poll pg_isready until ready
    Make->>Compose: up flyway-init fixture-load
    Compose->>FW: start
    FW->>PG: flyway migrate (V* + R__*)
    FW-->>Compose: exit 0
    Compose->>FX: start (after flyway-init succeeds)
    FX->>FX: cache hit, or download FIXTURE_URL, or committed synthetic sample
    FX->>PG: TRUNCATE + COPY into raw.pdl_person
    FX-->>Compose: exit 0
    Make-->>Eng: ✓ ready — postgres on localhost:5432
```

First run takes about a minute (image pulls + migrations + fixture); a warm restart takes seconds.

## 9. What we deliberately don't do

| Skipping | Why |
|---|---|
| **Orchestration** | Each step is a CLI; `make pipeline-pdl` chains ingest + dbt. Nothing else is needed to exercise the full chain. |
| **Running pipeline code in containers** | dbt, the ingester and the PDL API callers run on the host in `pdl_test`; containers only provide Postgres and local S3. |
| **Secrets service** | Plain env vars + a gitignored `.env`. |
| **A broader AWS emulator** (e.g. LocalStack) or a standalone object store | S3 is the only AWS service the pipeline uses. moto server covers it in a small container, is the same library the unit tests already use (one S3 emulation for tests and local runs), and needs no volume or credentials setup. The trade-off is no persistence and no web console. |
| **Log aggregation** | Container output via `make dev-logs`; pipeline CLIs log to stderr (`LOG_LEVEL` controls verbosity). |
| **Committed fixtures with real data** | The only committed fixture is fully synthetic (`generate-sample-fixture.py`); sanitized samples of real deliveries are supplied via `FIXTURE_URL` or the local cache directory, never committed. |

## 10. Risks + mitigations

| Risk | Mitigation |
|---|---|
| Fixture drifts from current PDL response shape | Version the fixture (`FIXTURE_VERSION`, `-v1`, `-v2`, …); extend `generate-sample-fixture.py` when staging starts reading a new PDL field, or regenerate a sanitized sample from a recent delivery with `sanitize-pdl-fixture.py`. |
| No fixture available (custom `FIXTURE_VERSION` with no committed file, no `FIXTURE_URL`, empty cache) | The committed synthetic sample covers the default version; otherwise `fixture-load` and `s3-init` skip gracefully and migrations still apply. |
| Postgres major-version bump breaks an existing volume | Image tag is pinned; bump deliberately and `make dev-reset` (or `pg_upgrade`). |
| Docker runs out of memory | The default profile is just Postgres; add `ingester` only when needed. |
| `pdl_full_local.yaml` drifts from `pdl_full.yaml` | The two must stay identical except `bucket`; change both together. |
| Local S3 is empty after a container restart (`NoSuchBucket`, Finder can't find `COMPLETED`) | moto server keeps state in memory; re-run `make dev-up-ingester` to re-seed. |
| With Colima, bind-mounted dirs (`infra/local/...`) appear empty in containers | Colima only shares `$HOME` with containers by default; clone the repo under your home directory. |
