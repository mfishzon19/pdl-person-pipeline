{#-
  staging.pdl_person_experience_parsed — PDL experience[] array unnested
  via JSON_TABLE NESTED PATH.

  Reference pattern for unnesting PDL sub-object arrays (education[] and
  the companies / schools / addresses models follow it). Simple text arrays
  (skills[], interests[], location_names[], countries[], regions[]) skip a
  _parsed table and live as jsonb on pdl_person_parsed — see that model.

    1. Outer SELECT captures partition_id + loaded_at from raw.pdl_person
       (PER-ROW context; not inside JSON_TABLE).
    2. JSON_TABLE root path is '$', with the parent's natural key
       (person_pdl_id) pulled via PATH '$.id'.
    3. A single NESTED PATH '$.<array>[*]' enters the array. Inside that
       block:
         - FOR ORDINALITY gives a 1-based index column preserving array
           order (here: experience_idx).
         - Each child field is PATH '$.field' with an inline type cast.
         - Multi-valued sub-fields (e.g. title.levels[], location_names[])
           are kept as jsonb to avoid row multiplication. integration
           projects them into junction tables.

  Grain: one row per (raw.pdl_person record × experience array entry).

  Source of truth for shape: docs/data_model/13_person.md §6.4 + PDL
  person.experience[] schema. DDL lives in V7__staging_baseline.sql + V9
  (year columns). on_schema_change='fail' enforces SELECT shape matches the
  table.

  Materialization inherited from dbt_project.yml staging defaults:
    materialized='incremental' + incremental_strategy='append' +
    pre_hook=TRUNCATE ... RESTART IDENTITY CASCADE + on_schema_change='fail'.

  Date handling: PDL ships start_date / end_date as "yyyy", "yyyy-mm", or
  "yyyy-mm-dd", most often yyyy-mm. Year-only is the agreed cross-table
  convention; we lose the month here knowingly. Read the field as text, extract the first 4 chars as int4
  in the outer SELECT. NULL passes through substring(NULL ...) cleanly.
-#}

SELECT
    r.partition_id,
    r.loaded_at,
    jt.person_pdl_id,
    jt.experience_idx,
    substring(jt.start_date_text FROM 1 FOR 4)::int4 AS start_year,
    substring(jt.end_date_text   FROM 1 FOR 4)::int4 AS end_year,
    jt.is_primary,
    jt.summary,
    jt.first_seen,
    jt.last_seen,
    jt.num_sources,
    jt.title_name,
    jt.title_role,
    jt.title_sub_role,
    jt.title_class,
    jt.title_levels,
    jt.title_raw,
    jt.company_pdl_id,
    jt.company_name,
    jt.company_size,
    jt.company_type,
    jt.company_founded,
    jt.company_industry,
    jt.company_industry_v2,
    jt.company_ticker,
    jt.company_website,
    jt.company_linkedin_url,
    jt.company_linkedin_id,
    jt.company_facebook_url,
    jt.company_twitter_url,
    jt.company_location_name,
    jt.company_location_street_address,
    jt.company_location_address_line_2,
    jt.company_location_locality,
    jt.company_location_region,
    jt.company_location_country,
    jt.company_location_continent,
    jt.company_location_metro,
    jt.company_location_postal_code,
    jt.company_location_geo,
    jt.location_names,
    jt.raw_names
FROM {{ source('raw', 'pdl_person') }} r,
     JSON_TABLE(
       r.payload,
       '$'
       COLUMNS (
         person_pdl_id  text  PATH '$.id',
         NESTED PATH '$.experience[*]'
         COLUMNS (
           experience_idx                            FOR ORDINALITY,

           -- Per-experience scalars (start_date / end_date kept as text
           -- so the outer SELECT can extract just the year — PDL sends
           -- yyyy, yyyy-mm, or yyyy-mm-dd; we store only the year.)
           start_date_text                           text          PATH '$.start_date',
           end_date_text                             text          PATH '$.end_date',
           is_primary                                bool          PATH '$.is_primary',
           summary                                   text          PATH '$.summary',
           first_seen                                timestamptz   PATH '$.first_seen',
           last_seen                                 timestamptz   PATH '$.last_seen',
           num_sources                               int4          PATH '$.num_sources',

           -- Title (levels[] + raw[] kept as jsonb sub-documents)
           title_name                                text          PATH '$.title.name',
           title_role                                text          PATH '$.title.role',
           title_sub_role                            text          PATH '$.title.sub_role',
           title_class                               text          PATH '$.title.class',
           title_levels                              jsonb         FORMAT JSON PATH '$.title.levels',
           title_raw                                 jsonb         FORMAT JSON PATH '$.title.raw',

           -- Company sub-object
           company_pdl_id                            text          PATH '$.company.id',
           company_name                              text          PATH '$.company.name',
           company_size                              text          PATH '$.company.size',
           company_type                              text          PATH '$.company.type',
           company_founded                           int4          PATH '$.company.founded',
           company_industry                          text          PATH '$.company.industry',
           company_industry_v2                       text          PATH '$.company.industry_v2',
           company_ticker                            text          PATH '$.company.ticker',
           company_website                           text          PATH '$.company.website',
           company_linkedin_url                      text          PATH '$.company.linkedin_url',
           company_linkedin_id                       text          PATH '$.company.linkedin_id',
           company_facebook_url                      text          PATH '$.company.facebook_url',
           company_twitter_url                       text          PATH '$.company.twitter_url',

           -- Company location (per-experience.company.location)
           company_location_name                     text          PATH '$.company.location.name',
           company_location_street_address           text          PATH '$.company.location.street_address',
           company_location_address_line_2           text          PATH '$.company.location.address_line_2',
           company_location_locality                 text          PATH '$.company.location.locality',
           company_location_region                   text          PATH '$.company.location.region',
           company_location_country                  text          PATH '$.company.location.country',
           company_location_continent                text          PATH '$.company.location.continent',
           company_location_metro                    text          PATH '$.company.location.metro',
           company_location_postal_code              text          PATH '$.company.location.postal_code',
           company_location_geo                      text          PATH '$.company.location.geo',

           -- Multi-valued per-experience attributes (jsonb; not row-unnested)
           location_names                            jsonb         FORMAT JSON PATH '$.location_names',
           raw_names                                 jsonb         FORMAT JSON PATH '$.raw'
         )
       )
     ) AS jt
-- JSON_TABLE NESTED PATH default outer-join semantics emit one row with
-- NULL experience_idx per raw record whose $.experience[*] is empty /
-- missing. Exclude those rows so staging holds
-- one row per real experience entry. Pairs with the not_null data_test
-- on experience_idx in schema.yml.
WHERE jt.experience_idx IS NOT NULL
