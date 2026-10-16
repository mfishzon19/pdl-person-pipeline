{#-
  staging.pdl_person_addresses_parsed — PDL addresses unified across 3 source
  paths inside a single PDL person payload, via UNION ALL.

  Each branch produces the same 15-column shape; per-branch NULLs fill the
  columns the source path doesn't carry. `source_context` distinguishes the
  three branches.

  Branches:
    1. 'person_home' — top-level scalars on raw.pdl_person.payload
       ($.location_*). source_idx = 0 (sentinel).
       street_address + address_line_2 are PDL bool-placeholders
       (the strings "true" / "false", never a real address); hardcoded
       NULL here.
    2. 'experience_company_hq' — nested $.experience[*].company.location.
       source_idx = experience_idx (FOR ORDINALITY). The only branch
       where street_address carries real values (when PDL has them).
    3. 'education_school' — nested $.education[*].school.location.
       source_idx = education_idx. Coarse-grain only — PDL does not emit
       metro / street_address / address_line_2 / postal_code / geo for
       schools; those columns are NULL.

  Why no 'job_company_hq' branch: $.job_company_location_* duplicates the
  is_primary experience entry's company location — covered by branch 2.
  See docs/design/15 decision #3.

  Filters out fully-NULL location rows at the WHERE clause (a record with
  no location data at all shouldn't produce an address row).

  Source-of-truth shape: modeling/dbml/staging.dbml block
  `staging.pdl_person_addresses_parsed`. DDL in
  V12__staging_new_parsed_and_unique_tables.sql.

  Materialization inherited from dbt_project.yml staging defaults:
    incremental + append + pre_hook=TRUNCATE + on_schema_change=fail.
-#}

-- Branch 1: person_home (top-level scalars)
-- street_address + address_line_2 hardcoded NULL (PDL bool-placeholders).
SELECT
    r.partition_id,
    r.loaded_at,
    r.payload->>'id'                                AS person_pdl_id,
    'person_home'::text                             AS source_context,
    0::int4                                         AS source_idx,
    r.payload->>'location_name'                     AS name,
    r.payload->>'location_locality'                 AS locality,
    r.payload->>'location_region'                   AS region,
    r.payload->>'location_country'                  AS country,
    r.payload->>'location_metro'                    AS metro,
    r.payload->>'location_continent'                AS continent,
    NULL::text                                      AS street_address,
    NULL::text                                      AS address_line_2,
    r.payload->>'location_postal_code'              AS postal_code,
    r.payload->>'location_geo'                      AS geo
FROM {{ source('raw', 'pdl_person') }} r
-- Keep a row if PDL filled any "useful" location field. street_address +
-- address_line_2 are bool-placeholders (already hardcoded NULL above);
-- metro / postal_code / continent are not enough on their own.
WHERE COALESCE(
        r.payload->>'location_name',
        r.payload->>'location_locality',
        r.payload->>'location_region',
        r.payload->>'location_country',
        r.payload->>'location_geo'
      ) IS NOT NULL

UNION ALL

-- Branch 2: experience_company_hq (nested under $.experience[*].company.location)
SELECT
    r.partition_id,
    r.loaded_at,
    jt.person_pdl_id,
    'experience_company_hq'::text                   AS source_context,
    jt.experience_idx::int4                         AS source_idx,
    jt.name,
    jt.locality,
    jt.region,
    jt.country,
    jt.metro,
    jt.continent,
    jt.street_address,
    jt.address_line_2,
    jt.postal_code,
    jt.geo
FROM {{ source('raw', 'pdl_person') }} r,
     JSON_TABLE(
       r.payload, '$'
       COLUMNS (
         person_pdl_id  text  PATH '$.id',
         NESTED PATH '$.experience[*]'
         COLUMNS (
           experience_idx  FOR ORDINALITY,
           name            text  PATH '$.company.location.name',
           locality        text  PATH '$.company.location.locality',
           region          text  PATH '$.company.location.region',
           country         text  PATH '$.company.location.country',
           metro           text  PATH '$.company.location.metro',
           continent       text  PATH '$.company.location.continent',
           street_address  text  PATH '$.company.location.street_address',
           address_line_2  text  PATH '$.company.location.address_line_2',
           postal_code     text  PATH '$.company.location.postal_code',
           geo             text  PATH '$.company.location.geo'
         )
       )
     ) AS jt
-- Includes street_address — this is the one branch where PDL emits real
-- street values. Otherwise same shape as branch 1's filter.
WHERE COALESCE(jt.name, jt.locality, jt.region, jt.country, jt.street_address, jt.geo) IS NOT NULL

UNION ALL

-- Branch 3: education_school (nested under $.education[*].school.location)
-- Coarse-grain only: PDL does NOT emit street/metro/postal/geo for schools.
SELECT
    r.partition_id,
    r.loaded_at,
    jt.person_pdl_id,
    'education_school'::text                        AS source_context,
    jt.education_idx::int4                          AS source_idx,
    jt.name,
    jt.locality,
    jt.region,
    jt.country,
    NULL::text                                      AS metro,
    jt.continent,
    NULL::text                                      AS street_address,
    NULL::text                                      AS address_line_2,
    NULL::text                                      AS postal_code,
    NULL::text                                      AS geo
FROM {{ source('raw', 'pdl_person') }} r,
     JSON_TABLE(
       r.payload, '$'
       COLUMNS (
         person_pdl_id  text  PATH '$.id',
         NESTED PATH '$.education[*]'
         COLUMNS (
           education_idx  FOR ORDINALITY,
           name           text  PATH '$.school.location.name',
           locality       text  PATH '$.school.location.locality',
           region         text  PATH '$.school.location.region',
           country        text  PATH '$.school.location.country',
           continent      text  PATH '$.school.location.continent'
         )
       )
     ) AS jt
-- Includes continent — for schools PDL often emits ONLY continent +
-- country, so dropping it from the COALESCE would silently lose rows
-- that have a real continent value and nothing else.
WHERE COALESCE(jt.name, jt.locality, jt.region, jt.country, jt.continent) IS NOT NULL
