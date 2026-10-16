{#-
  staging.pdl_person_education_unique — PDL education deduplicated by
  4-column natural key.

  Natural key: (person_pdl_id, school_pdl_id, start_year, degrees_text).
  degrees_text is a plain text column on the target table, populated by
  this SELECT as `degrees::text`. Postgres UNIQUE constraints can't be
  defined directly on a jsonb expression, so the discriminator is
  materialized as text.

  On real deliveries, adding the degrees_text discriminator separated a
  large share of what a 3-column key would have treated as duplicates
  (e.g. two degrees from the same school and start year).

  Dedup ordering: loaded_at DESC, partition_id DESC
  (uniform placeholder).

  Source-of-truth shape: modeling/dbml/staging.dbml block
  `staging.pdl_person_education_unique`. DDL in
  V12__staging_new_parsed_and_unique_tables.sql + V13 (dropped the
  STORED GENERATED expression on degrees_text — see V13 header for the
  full rationale).

  Materialization inherited from dbt_project.yml staging defaults.
-#}

SELECT DISTINCT ON (person_pdl_id, school_pdl_id, start_year, degrees::text)
    partition_id,
    loaded_at,
    person_pdl_id,
    education_idx,
    start_year,
    end_year,
    gpa,
    summary,
    degrees,
    degrees::text                              AS degrees_text,
    majors,
    minors,
    raw_names,
    school_pdl_id,
    school_name,
    school_type,
    school_domain,
    school_website,
    school_linkedin_url,
    school_linkedin_id,
    school_facebook_url,
    school_twitter_url,
    school_location_continent,
    school_location_country,
    school_location_region,
    school_location_locality
FROM {{ ref('pdl_person_education_parsed') }}
ORDER BY person_pdl_id, school_pdl_id, start_year, degrees::text, loaded_at DESC, partition_id DESC
