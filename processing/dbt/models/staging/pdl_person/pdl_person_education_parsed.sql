{#-
  staging.pdl_person_education_parsed: PDL education[] array unnested
  via JSON_TABLE NESTED PATH.

  Follows the pdl_person_experience_parsed.sql pattern; same shape,
  different array path ($.education[*]).

  Grain: one row per (raw.pdl_person record × education array entry).

  Source of truth for shape: modeling/dbml/staging.dbml block
  `staging.pdl_person_education_parsed`. DDL in V7__staging_baseline.sql
  + V8 (year columns). PDL field paths from docs/data_model/13_person.md
  §6.5 + PDL person.education[] schema. on_schema_change='fail' enforces
  SELECT shape matches the table.

  Materialization inherited from dbt_project.yml staging defaults:
    materialized='incremental' + incremental_strategy='append' +
    pre_hook=TRUNCATE ... RESTART IDENTITY CASCADE + on_schema_change='fail'.

  School sub-object: coarse-grain location only (continent / country /
  region / locality). PDL doesn't emit street-level for schools.
  degrees / majors / minors / raw kept as jsonb to avoid row
  multiplication; integration unnests them into junctions if needed.

  Date handling: PDL ships start_date / end_date as "yyyy", "yyyy-mm", or
  "yyyy-mm-dd", and year-only is common for education. A `date` cast would
  turn year-only values into NULL (NULL ON ERROR), so the field is read as
  text inside JSON_TABLE and the first 4 chars are extracted as int4 in the
  outer SELECT. NULL passes through `substring(NULL ...)` cleanly.
-#}

SELECT
    r.partition_id,
    r.loaded_at,
    jt.person_pdl_id,
    jt.education_idx,
    substring(jt.start_date_text FROM 1 FOR 4)::int4 AS start_year,
    substring(jt.end_date_text   FROM 1 FOR 4)::int4 AS end_year,
    jt.gpa,
    jt.summary,
    jt.degrees,
    jt.majors,
    jt.minors,
    jt.raw_names,
    jt.school_pdl_id,
    jt.school_name,
    jt.school_type,
    jt.school_domain,
    jt.school_website,
    jt.school_linkedin_url,
    jt.school_linkedin_id,
    jt.school_facebook_url,
    jt.school_twitter_url,
    jt.school_location_continent,
    jt.school_location_country,
    jt.school_location_region,
    jt.school_location_locality
FROM {{ source('raw', 'pdl_person') }} r,
     JSON_TABLE(
       r.payload,
       '$'
       COLUMNS (
         person_pdl_id  text  PATH '$.id',
         NESTED PATH '$.education[*]'
         COLUMNS (
           education_idx                             FOR ORDINALITY,

           -- Per-education scalars (start_date / end_date kept as text
           -- so the outer SELECT can extract just the year — PDL sends
           -- yyyy, yyyy-mm, or yyyy-mm-dd; we store only the year.)
           start_date_text                           text           PATH '$.start_date',
           end_date_text                             text           PATH '$.end_date',
           gpa                                       numeric(4,2)   PATH '$.gpa',
           summary                                   text           PATH '$.summary',

           -- Multi-valued per-education attributes (jsonb; not row-unnested)
           degrees                                   jsonb          FORMAT JSON PATH '$.degrees',
           majors                                    jsonb          FORMAT JSON PATH '$.majors',
           minors                                    jsonb          FORMAT JSON PATH '$.minors',
           raw_names                                 jsonb          FORMAT JSON PATH '$.raw',

           -- School sub-object (scalars)
           school_pdl_id                             text           PATH '$.school.id',
           school_name                               text           PATH '$.school.name',
           school_type                               text           PATH '$.school.type',
           school_domain                             text           PATH '$.school.domain',
           school_website                            text           PATH '$.school.website',
           school_linkedin_url                       text           PATH '$.school.linkedin_url',
           school_linkedin_id                        text           PATH '$.school.linkedin_id',
           school_facebook_url                       text           PATH '$.school.facebook_url',
           school_twitter_url                        text           PATH '$.school.twitter_url',

           -- School location (coarse-grain only)
           school_location_continent                 text           PATH '$.school.location.continent',
           school_location_country                   text           PATH '$.school.location.country',
           school_location_region                    text           PATH '$.school.location.region',
           school_location_locality                  text           PATH '$.school.location.locality'
         )
       )
     ) AS jt
-- JSON_TABLE NESTED PATH default outer-join semantics emit one row with
-- NULL education_idx per raw record whose $.education[*] is empty /
-- missing. Exclude those rows so staging holds
-- one row per real education entry. Pairs with the not_null data_test
-- on education_idx in schema.yml.
WHERE jt.education_idx IS NOT NULL
