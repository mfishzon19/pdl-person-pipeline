# processing/

Code that moves and transforms data through the schemas defined in [`../modeling/`](../modeling/). Architecture: [`docs/design/02_pipeline_design.md`](../docs/design/02_pipeline_design.md).

## Subdirectories

- [`s3_ingester/`](s3_ingester/) — pipeline step 1. Config-driven S3 → Postgres ingestion of PDL Person deliveries: `finder.py` (discovers a delivery's files, writes `catalog.pipeline_run` / `ingestion_run` / `ingestion_file` rows), `delivery_loader.py` (loops over pending files), `file_ingester.py` (per-file primitive — download from S3, gunzip, TRUNCATE + psycopg2 `COPY` into the `raw.*` leaf partition), `pdl_projection_runner.py` (projects merged / deleted / opted-out deltas into the `catalog` identity ledger), `run.py` (chains Finder → Loader → projection for one delivery). Per-source YAML in `s3_ingester/configs/`.
- [`pdl_api/`](pdl_api/) — pipeline step 3. Generic PDL API caller: company enrichment plus company / location / school cleaners. Reads driver views in the `pdl_api` schema, writes one audit row per call. Design: [`docs/design/18_pdl_api_generic_caller.md`](../docs/design/18_pdl_api_generic_caller.md).
- [`common/`](common/) — cross-cutting helpers (Postgres, S3 / Secrets Manager wrappers, PDL HTTP client, delivery preflight checks). One-way dependency: consumers import `common`, never the reverse.
- [`dbt/`](dbt/) — dbt Core project: pipeline steps 2 and 4 (`staging` → `ref` → `integration`). Layer model: [`docs/design/16_dbt_pipeline_layers.md`](../docs/design/16_dbt_pipeline_layers.md).
- `tests/` — tests for top-level shared modules (`common/logging_setup.py`); each package keeps its own tests next to the code.

Cleansing (step 5) is still in R&D form under [`docs/pdl_data_cleansing/`](../docs/pdl_data_cleansing/); its pipeline target is `_cleaned` dbt models plus Postgres functions.

## What this layer does NOT do

- **Define schema.** Tables are authored in `../modeling/dbml/` and applied by Flyway (`flyway-init` in Docker Compose). The processing layer never issues `CREATE TABLE` against schemas it does not own (the ingester only creates `raw.*` leaf partitions under parents Flyway created).
- **Hold credentials.** Everything comes from environment variables (`DATABASE_URL`, `PDL_API_KEY`, AWS credential chain / `AWS_PROFILE`, `AWS_ENDPOINT_URL` for local S3).

## Running

Use the make targets from the repo root (`make ingest-pdl`, `make dbt-pdl`, `make pipeline-pdl`; for the live PDL API, `make clean-pdl` and `make enrich-pdl SOURCE_LIST=x MAX_CREDITS=n`) or call the modules directly — see [`s3_ingester/README.md`](s3_ingester/README.md) and [`pdl_api/README.md`](pdl_api/README.md).
