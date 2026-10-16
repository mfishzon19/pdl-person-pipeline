{#-
  staging.pdl_person_parsed — faithful flatten of PDL person top-level
  scalar fields from raw.pdl_person.payload (jsonb).

  Source of truth for what we capture: docs/data_model/13_person.md §6 +
  the full PDL person schema (https://docs.peopledatalabs.com/docs/person-schema).

  Why JSON_TABLE: cleaner than a wall of payload->>'field' operators;
  inline type casts via PATH ... <type>; standard SQL/JSON syntax (PG17+).

  What this model is:
    - One row per raw.pdl_person record (1:1 with raw).
    - All top-level scalars PDL emits, even fields integration drops
      (e.g., job_company_*, job_onet_*, social-network duplicates of
      profiles[]). Staging is a faithful flatten; integration picks what
      to keep.
    - 5 simple text arrays kept as jsonb columns (skills, interests,
      location_names, countries, regions). These don't warrant their own
      _parsed table — ref / integration models unnest them via
      jsonb_array_elements_text() at consume time and dedup happens in
      the ref layer.

  What this model is NOT:
    - No sub-object array unnesting (experience[], education[]) — those go
      to separate pdl_person_*_parsed models.
    - No dedup or alias resolution (handled in pdl_person_unique).
    - No PII fields (birth_date, emails[], phones[], possible_*) — excluded
      by design per docs/data_model/13_person.md §6.1.

  Materialization inherited from dbt_project.yml staging defaults:
    materialized='incremental' + incremental_strategy='append' +
    pre_hook=TRUNCATE ... RESTART IDENTITY CASCADE + on_schema_change='fail'.

  The DDL for staging.pdl_person_parsed lives in V7__staging_baseline.sql
  + V9 (year columns). on_schema_change='fail' enforces that the SELECT
  column list below matches the Flyway table shape exactly. When
  adding/removing/renaming a column: edit DBML → add ALTER migration →
  flyway-apply → update the SELECT here (or vice versa, whichever is your
  starting point). dbt errors if they drift.

  Date handling: PDL ships job_start_date as
  "yyyy", "yyyy-mm", or "yyyy-mm-dd". Year-only is the agreed cross-table
  convention. job_start_date_text is read as text in JSON_TABLE; the year
  is extracted via substring(... from 1 for 4)::int4 in the outer SELECT.
  job_last_changed / job_last_verified are system timestamps from PDL —
  always full date, kept as `date`.
-#}

SELECT
    r.partition_id,
    r.loaded_at,
    jt.pdl_id,
    jt.first_seen,
    jt.num_sources,
    jt.num_records,
    jt.dataset_version,
    jt.operation_id,
    jt.first_name,
    jt.middle_name,
    jt.middle_initial,
    jt.last_name,
    jt.last_initial,
    jt.full_name,
    jt.headline,
    jt.summary,
    jt.industry,
    jt.sex,
    jt.inferred_years_experience,
    jt.inferred_salary,
    jt.work_email,
    jt.job_title,
    jt.job_title_role,
    jt.job_title_sub_role,
    jt.job_title_class,
    substring(jt.job_start_date_text FROM 1 FOR 4)::int4 AS job_start_year,
    jt.job_last_changed,
    jt.job_last_verified,
    jt.job_summary,
    jt.job_onet_code,
    jt.job_onet_major_group,
    jt.job_onet_minor_group,
    jt.job_onet_broad_occupation,
    jt.job_onet_specific_occupation,
    jt.job_onet_specific_occupation_detail,
    jt.job_company_name,
    jt.job_company_id,
    jt.job_company_website,
    jt.job_company_industry,
    jt.job_company_industry_v2,
    jt.job_company_size,
    jt.job_company_type,
    jt.job_company_founded,
    jt.job_company_employee_count,
    jt.job_company_inferred_revenue,
    jt.job_company_total_funding_raised,
    jt.job_company_ticker,
    jt.job_company_linkedin_url,
    jt.job_company_linkedin_id,
    jt.job_company_facebook_url,
    jt.job_company_twitter_url,
    jt.job_company_12mo_employee_growth_rate,
    jt.job_company_location_name,
    jt.job_company_location_street_address,
    jt.job_company_location_address_line_2,
    jt.job_company_location_locality,
    jt.job_company_location_region,
    jt.job_company_location_country,
    jt.job_company_location_continent,
    jt.job_company_location_metro,
    jt.job_company_location_postal_code,
    jt.job_company_location_geo,
    jt.linkedin_id,
    jt.linkedin_url,
    jt.linkedin_username,
    jt.linkedin_connections,
    jt.facebook_friends,
    jt.location_name,
    jt.location_locality,
    jt.location_region,
    jt.location_country,
    jt.location_continent,
    jt.location_metro,
    jt.location_postal_code,
    jt.location_geo,
    jt.location_last_updated,
    jt.skills,
    jt.interests,
    jt.location_names,
    jt.countries,
    jt.regions
FROM {{ source('raw', 'pdl_person') }} r,
     JSON_TABLE(
       r.payload,
       '$'
       COLUMNS (
         -- Record metadata
         pdl_id                                     text         PATH '$.id',
         first_seen                                 timestamptz  PATH '$.first_seen',
         num_sources                                int4         PATH '$.num_sources',
         num_records                                int4         PATH '$.num_records',
         dataset_version                            text         PATH '$.dataset_version',
         operation_id                               text         PATH '$.operation_id',

         -- Names
         first_name                                 text         PATH '$.first_name',
         middle_name                                text         PATH '$.middle_name',
         middle_initial                             text         PATH '$.middle_initial',
         last_name                                  text         PATH '$.last_name',
         last_initial                               text         PATH '$.last_initial',
         full_name                                  text         PATH '$.full_name',

         -- Bio
         headline                                   text         PATH '$.headline',
         summary                                    text         PATH '$.summary',
         industry                                   text         PATH '$.industry',
         sex                                        text         PATH '$.sex',

         -- Inferred
         inferred_years_experience                  int4         PATH '$.inferred_years_experience',
         inferred_salary                            text         PATH '$.inferred_salary',

         -- Contact (PII-allowed subset; emails[] / phones[] / mobile_phone
         -- excluded)
         work_email                                 text         PATH '$.work_email',

         -- Current job (flat — duplicate of experience[is_primary]; kept for
         -- faithful flatten; integration deduplicates)
         job_title                                  text         PATH '$.job_title',
         job_title_role                             text         PATH '$.job_title_role',
         job_title_sub_role                         text         PATH '$.job_title_sub_role',
         job_title_class                            text         PATH '$.job_title_class',
         job_start_date_text                        text         PATH '$.job_start_date',
         job_last_changed                           date         PATH '$.job_last_changed',
         job_last_verified                          date         PATH '$.job_last_verified',
         job_summary                                text         PATH '$.job_summary',
         job_onet_code                              text         PATH '$.job_onet_code',
         job_onet_major_group                       text         PATH '$.job_onet_major_group',
         job_onet_minor_group                       text         PATH '$.job_onet_minor_group',
         job_onet_broad_occupation                  text         PATH '$.job_onet_broad_occupation',
         job_onet_specific_occupation               text         PATH '$.job_onet_specific_occupation',
         job_onet_specific_occupation_detail        text         PATH '$.job_onet_specific_occupation_detail',

         -- Current company (flat)
         job_company_name                           text         PATH '$.job_company_name',
         job_company_id                             text         PATH '$.job_company_id',
         job_company_website                        text         PATH '$.job_company_website',
         job_company_industry                       text         PATH '$.job_company_industry',
         job_company_industry_v2                    text         PATH '$.job_company_industry_v2',
         job_company_size                           text         PATH '$.job_company_size',
         job_company_type                           text         PATH '$.job_company_type',
         job_company_founded                        int4         PATH '$.job_company_founded',
         job_company_employee_count                 int4         PATH '$.job_company_employee_count',
         job_company_inferred_revenue               text         PATH '$.job_company_inferred_revenue',
         job_company_total_funding_raised           int8         PATH '$.job_company_total_funding_raised',
         job_company_ticker                         text         PATH '$.job_company_ticker',
         job_company_linkedin_url                   text         PATH '$.job_company_linkedin_url',
         job_company_linkedin_id                    text         PATH '$.job_company_linkedin_id',
         job_company_facebook_url                   text         PATH '$.job_company_facebook_url',
         job_company_twitter_url                    text         PATH '$.job_company_twitter_url',
         job_company_12mo_employee_growth_rate      numeric(7,4) PATH '$.job_company_12mo_employee_growth_rate',

         -- Current company location (flat)
         job_company_location_name                  text         PATH '$.job_company_location_name',
         job_company_location_street_address        text         PATH '$.job_company_location_street_address',
         job_company_location_address_line_2        text         PATH '$.job_company_location_address_line_2',
         job_company_location_locality              text         PATH '$.job_company_location_locality',
         job_company_location_region                text         PATH '$.job_company_location_region',
         job_company_location_country               text         PATH '$.job_company_location_country',
         job_company_location_continent             text         PATH '$.job_company_location_continent',
         job_company_location_metro                 text         PATH '$.job_company_location_metro',
         job_company_location_postal_code           text         PATH '$.job_company_location_postal_code',
         job_company_location_geo                   text         PATH '$.job_company_location_geo',

         -- Social — LinkedIn at top level (canonical primary)
         linkedin_id                                text         PATH '$.linkedin_id',
         linkedin_url                               text         PATH '$.linkedin_url',
         linkedin_username                          text         PATH '$.linkedin_username',
         linkedin_connections                       int4         PATH '$.linkedin_connections',

         -- Social — facebook/twitter/github URL+id+username columns carried
         -- only boolean placeholders on this PDL subscription tier and were
         -- dropped in V16. facebook_friends (always NULL) is kept for now.
         facebook_friends                           int4         PATH '$.facebook_friends',

         -- Person home location (flat). location_street_address +
         -- address_line_2 are bool-placeholders at person-home grain (dropped in V16).
         location_name                              text         PATH '$.location_name',
         location_locality                          text         PATH '$.location_locality',
         location_region                            text         PATH '$.location_region',
         location_country                           text         PATH '$.location_country',
         location_continent                         text         PATH '$.location_continent',
         location_metro                             text         PATH '$.location_metro',
         location_postal_code                       text         PATH '$.location_postal_code',
         location_geo                               text         PATH '$.location_geo',
         location_last_updated                      date         PATH '$.location_last_updated',

         -- Simple text arrays kept as jsonb (no per-entry sub-object).
         -- ref / integration models unnest via jsonb_array_elements_text() to
         -- populate ref tables + junction tables.
         skills                                     jsonb        FORMAT JSON PATH '$.skills',
         interests                                  jsonb        FORMAT JSON PATH '$.interests',
         location_names                             jsonb        FORMAT JSON PATH '$.location_names',
         countries                                  jsonb        FORMAT JSON PATH '$.countries',
         regions                                    jsonb        FORMAT JSON PATH '$.regions'
       )
     ) AS jt
