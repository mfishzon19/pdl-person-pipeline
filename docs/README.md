# Docs

Documentation for the local PDL pipeline. The project front page with quickstart is the [top-level README](../README.md).

## Docs by pipeline step

| Step | What happens | Read |
|---|---|---|
| 1. Ingest | PDL Person deliveries from S3 / MinIO → `raw.*`; delta files → `catalog` identity ledger | [design/02 §5–6, §9–10](design/02_pipeline_design.md), [processing/s3_ingester](../processing/s3_ingester/README.md), [requirements/01](requirements/01_pipeline_requirements.md) |
| 2. Parse | dbt staging: `staging.pdl_person_*_parsed` → `_unique` | [design/15](design/15_pdl_staging_design.md), [design/16](design/16_dbt_pipeline_layers.md) |
| 3. PDL API | Company enrichment + company / location / school cleaners → `pdl_api.*` → `staging.pdl_api_company_parsed` | [design/18](design/18_pdl_api_generic_caller.md), [processing/pdl_api](../processing/pdl_api/README.md) |
| 4. Model | `ref.*` + `integration.*` — the data model | [data_model/](data_model/README.md), [decisions/](decisions/README.md) |
| 5. Cleanse | Normalization, broken-company removal, dedup, degree families, school rollup, company hierarchy | [design/21](design/21_cleansing_layer_design.md), [pdl_data_cleansing/](pdl_data_cleansing/README.md) |

Running it locally: [design/local-dev-design.md](design/local-dev-design.md). Testing: [design/07_test_plan.md](design/07_test_plan.md).

## Directories

- **[requirements/](requirements/)** — what the pipeline must deliver.
- **[design/](design/)** — how it is built: architecture, staging, dbt layers, PDL API caller, cleansing layer, shared libraries, local environment, test plan.
- **[data_model/](data_model/)** — prose for the `ref.*` and `integration.*` schemas (the contract itself is `modeling/dbml/`).
- **[decisions/](decisions/)** — architecture decision records (ADRs).
- **[pdl_data_cleansing/](pdl_data_cleansing/)** — the cleansing routines: SQL / Python per routine, with inputs, outputs and order of application.

Each subdirectory has its own `README.md` with a file index and one-line descriptions.

## Conventions

- **README-first for docs-tree changes** — any change that adds, removes or renames a file under `docs/**` also updates that subdirectory's README in the same change (see [CLAUDE.md](../CLAUDE.md)).
- **Docs-first for design changes** — DBML, migration, dbt-structure or pipeline-shape changes ship with the matching doc update.
- **Table of contents** — long design docs (500+ lines) carry a manually maintained TOC near the top; update it when sections change.
- **Client-neutral** — no client names, people's names, or real person / company records. Examples use placeholders (Acme Corp, Jane Doe).
