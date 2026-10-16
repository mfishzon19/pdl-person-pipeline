{#-
  staging.pdl_person_addresses_unique — PDL addresses deduplicated by
  source-position identity.

  Natural key: (person_pdl_id, source_context, source_idx). One row per
  unique source position. Dedup ordering: loaded_at DESC,
  partition_id DESC (the uniform placeholder).

  Source-of-truth shape: modeling/dbml/staging.dbml block
  `staging.pdl_person_addresses_unique`. DDL in
  V12__staging_new_parsed_and_unique_tables.sql.

  Materialization inherited from dbt_project.yml staging defaults.
-#}

SELECT DISTINCT ON (person_pdl_id, source_context, source_idx)
    partition_id,
    loaded_at,
    person_pdl_id,
    source_context,
    source_idx,
    name,
    locality,
    region,
    country,
    metro,
    continent,
    street_address,
    address_line_2,
    postal_code,
    geo
FROM {{ ref('pdl_person_addresses_parsed') }}
ORDER BY person_pdl_id, source_context, source_idx, loaded_at DESC, partition_id DESC
