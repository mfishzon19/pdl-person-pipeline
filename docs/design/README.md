# Design

Design specs for the PDL pipeline (how it is built). Pair with [`../requirements/`](../requirements/) (what it delivers), [`../data_model/`](../data_model/) (the resulting schema) and [`../decisions/`](../decisions/) (formal ADRs).

- [02_pipeline_design.md](02_pipeline_design.md) — central pipeline design: the five-step local PDL flow, S3 layout, raw partitioning, ingester framework, PDL API placement, dbt layers, identity ledger, catalog logging (§10), DBML / Flyway migration conventions (§11).
- [07_test_plan.md](07_test_plan.md) — tiered pytest plan (tier1/2/3, integration, opt-in `pdl_smoke`) for the ingester and PDL API callers; PDL is always mocked.
- [15_pdl_staging_design.md](15_pdl_staging_design.md) — PDL Person staging: which nested objects become parsed tables, the 3-path address union, sibling parsed models reading raw, natural keys and dedup rules for the unique tier.
- [16_dbt_pipeline_layers.md](16_dbt_pipeline_layers.md) — source-agnostic dbt layer model (raw / staging / ref / integration / catalog, plus the `pdl_api` cache), naming conventions, materialization recipe, DAG ordering, "siblings read raw".
- [18_pdl_api_generic_caller.md](18_pdl_api_generic_caller.md) — generic PDL API caller: `PDLCaller` / `BulkPDLCaller`, company enrichment and company / location / school cleaners, queue / view / audit tables, credit caps, crash recovery.
- [21_cleansing_layer_design.md](21_cleansing_layer_design.md) — cleansing layer design: cleansing classes, casing convention, function library, `_cleaned` model shape, and how each routine in [`../pdl_data_cleansing/`](../pdl_data_cleansing/) becomes a pipeline step.
- [common_libraries.md](common_libraries.md) — `processing.common.*` modules: db, aws (S3 / Secrets Manager), PDL HTTP client, preflight checks, logging setup.
- [local-dev-design.md](local-dev-design.md) — the local environment: Docker Compose services (Postgres, Flyway, fixture load, local S3 via moto server), the `pdl_test` conda env, make targets, env vars, troubleshooting.

Numbers reflect creation order, not reading order. Start with `02_pipeline_design.md`.
