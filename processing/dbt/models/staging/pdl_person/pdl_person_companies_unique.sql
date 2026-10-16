{#-
  staging.pdl_person_companies_unique — dedup of pdl_person_companies_parsed
  by company_pdl_id. One row per unique company across all (person × experience)
  source rows.

  Filters NULL company_pdl_id — experiences PDL didn't link to a tracked
  company don't contribute to the dim. Per docs/design/15 + the dbml NOT NULL
  constraint on company_pdl_id (also enforced by the unique constraint
  recreated in dbt_project.yml's post_hook).

  Dedup ordering (uniform placeholder): loaded_at DESC,
  partition_id DESC. Per-table tuning not implemented yet. The winning
  row's partition_id + loaded_at ride along on the DISTINCT ON.

  Per-row provenance (person_pdl_id, experience_idx) is dropped at this
  layer — _unique is per-company canonical, not per-occurrence. Integration
  entity rows that need provenance back to a specific experience JOIN
  through pdl_person_experience_unique → pdl_person_companies_unique
  (no provenance columns on the company row).

  Source-of-truth: modeling/dbml/staging.dbml (14 columns).
-#}

SELECT DISTINCT ON (company_pdl_id)
    partition_id,
    loaded_at,
    company_pdl_id,
    company_name,
    company_size,
    company_type,
    company_founded,
    company_industry,
    company_industry_v2,
    company_ticker,
    company_website,
    company_linkedin_url,
    company_linkedin_id,
    company_facebook_url,
    company_twitter_url
FROM {{ ref('pdl_person_companies_parsed') }}
WHERE company_pdl_id IS NOT NULL
ORDER BY company_pdl_id, loaded_at DESC, partition_id DESC
