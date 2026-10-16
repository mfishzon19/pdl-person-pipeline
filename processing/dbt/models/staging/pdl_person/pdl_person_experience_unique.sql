{#-
  staging.pdl_person_experience_unique — PDL experience deduplicated by
  4-column natural key.

  Natural key: (person_pdl_id, company_pdl_id, start_year, title_name).
  title_name is the discriminator that preserves promotion-style
  multi-title rows that a 3-column (person, company, start) key would
  have wrong-merged. On real deliveries, adding title_name reduced the
  remaining duplicate groups to a negligible residue.

  Dedup ordering: loaded_at DESC, partition_id DESC
  (uniform placeholder; per-table tuning not implemented yet).

  Source-of-truth shape: modeling/dbml/staging.dbml block
  `staging.pdl_person_experience_unique`. DDL in
  V12__staging_new_parsed_and_unique_tables.sql.

  Materialization inherited from dbt_project.yml staging defaults.
-#}

SELECT DISTINCT ON (person_pdl_id, company_pdl_id, start_year, title_name)
    partition_id,
    loaded_at,
    person_pdl_id,
    experience_idx,
    start_year,
    end_year,
    is_primary,
    summary,
    first_seen,
    last_seen,
    num_sources,
    title_name,
    title_role,
    title_sub_role,
    title_class,
    title_levels,
    title_raw,
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
    company_twitter_url,
    company_location_name,
    company_location_street_address,
    company_location_address_line_2,
    company_location_locality,
    company_location_region,
    company_location_country,
    company_location_continent,
    company_location_metro,
    company_location_postal_code,
    company_location_geo,
    location_names,
    raw_names
FROM {{ ref('pdl_person_experience_parsed') }}
ORDER BY person_pdl_id, company_pdl_id, start_year, title_name, loaded_at DESC, partition_id DESC
