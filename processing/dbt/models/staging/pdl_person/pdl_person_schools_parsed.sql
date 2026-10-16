{#-
  staging.pdl_person_schools_parsed — PDL education[].school sub-object
  flattened. One row per (raw.pdl_person record × education entry that has
  a school). Source for pdl_person_schools_unique (dedup by school_pdl_id).

  Selective normalization rule from docs/design/15 §1: school is its own staging
  table because integration consumes `integration.school` as a dim. Pattern
  is the mechanical sibling of pdl_person_companies_parsed — outer SELECT +
  JSON_TABLE root + one NESTED PATH into $.education[*], child columns
  scoped to $.school.*.

  School location is intentionally NOT here; nested location lives in
  pdl_person_addresses_parsed with source_context = 'education_school'
  (coarse-grain only — PDL doesn't emit street-level for schools, per
  docs/design/15 decision #3).

  Per-row WHERE filters drop two classes of junk at parsed time:
    - education_idx IS NOT NULL: drops raw rows with empty/missing
      $.education[*]. JSON_TABLE outer-join emits a NULL-ordinality
      row per such record.
    - school_pdl_id IS NOT NULL: drops education entries with no
      school link. schools_parsed is a sub-object extraction (school
      OUT OF education), so rows without a school id carry no signal
      — same rule as pdl_person_addresses_parsed dropping rows with
      no useful location data. Downstream consumer
      pdl_person_schools_unique can't dedup NULL ids anyway.

  Source-of-truth: modeling/dbml/staging.dbml (12 columns). docs/design/15 design.
-#}

SELECT
    r.partition_id,
    r.loaded_at,
    jt.person_pdl_id,
    jt.education_idx,
    jt.school_pdl_id,
    jt.school_name,
    jt.school_type,
    jt.school_domain,
    jt.school_website,
    jt.school_linkedin_url,
    jt.school_linkedin_id,
    jt.school_facebook_url,
    jt.school_twitter_url
FROM {{ source('raw', 'pdl_person') }} r,
     JSON_TABLE(
       r.payload,
       '$'
       COLUMNS (
         person_pdl_id  text  PATH '$.id',
         NESTED PATH '$.education[*]'
         COLUMNS (
           education_idx                            FOR ORDINALITY,
           school_pdl_id                            text  PATH '$.school.id',
           school_name                              text  PATH '$.school.name',
           school_type                              text  PATH '$.school.type',
           school_domain                            text  PATH '$.school.domain',
           school_website                           text  PATH '$.school.website',
           school_linkedin_url                      text  PATH '$.school.linkedin_url',
           school_linkedin_id                       text  PATH '$.school.linkedin_id',
           school_facebook_url                      text  PATH '$.school.facebook_url',
           school_twitter_url                       text  PATH '$.school.twitter_url'
         )
       )
     ) AS jt
WHERE jt.education_idx IS NOT NULL
  AND jt.school_pdl_id IS NOT NULL
