{#-
  staging.pdl_person_companies_parsed — PDL experience[].company sub-object
  flattened. One row per (raw.pdl_person record × experience entry that has
  a company). Source for pdl_person_companies_unique (dedup by company_pdl_id).

  Selective normalization rule from docs/design/15 §1: company is its own staging
  table because integration consumes `integration.company` as a dim. Pattern
  mirrors pdl_person_experience_parsed — outer SELECT + JSON_TABLE root +
  one NESTED PATH into $.experience[*], child columns scoped to $.company.*.

  Company location is intentionally NOT here; nested location lives in
  pdl_person_addresses_parsed with source_context = 'experience_company_hq'
  per docs/design/15 decision #3.

  Per-row WHERE filters drop two classes of junk at parsed time:
    - experience_idx IS NOT NULL: drops raw rows with empty/missing
      $.experience[*]. JSON_TABLE outer-join emits a NULL-ordinality
      row per such record. Same filter as pdl_person_experience_parsed.
    - company_pdl_id IS NOT NULL: drops experience entries with no
      company link. companies_parsed is a sub-object extraction
      (company OUT OF experience), so rows without a company id carry
      no signal — same rule as pdl_person_addresses_parsed dropping
      rows with no useful location data. Downstream consumer
      pdl_person_companies_unique can't dedup NULL ids anyway.

  Source-of-truth: modeling/dbml/staging.dbml (16 columns). docs/design/15 design.
-#}

SELECT
    r.partition_id,
    r.loaded_at,
    jt.person_pdl_id,
    jt.experience_idx,
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
    jt.company_twitter_url
FROM {{ source('raw', 'pdl_person') }} r,
     JSON_TABLE(
       r.payload,
       '$'
       COLUMNS (
         person_pdl_id  text  PATH '$.id',
         NESTED PATH '$.experience[*]'
         COLUMNS (
           experience_idx                            FOR ORDINALITY,
           company_pdl_id                            text  PATH '$.company.id',
           company_name                              text  PATH '$.company.name',
           company_size                              text  PATH '$.company.size',
           company_type                              text  PATH '$.company.type',
           company_founded                           int4  PATH '$.company.founded',
           company_industry                          text  PATH '$.company.industry',
           company_industry_v2                       text  PATH '$.company.industry_v2',
           company_ticker                            text  PATH '$.company.ticker',
           company_website                           text  PATH '$.company.website',
           company_linkedin_url                      text  PATH '$.company.linkedin_url',
           company_linkedin_id                       text  PATH '$.company.linkedin_id',
           company_facebook_url                      text  PATH '$.company.facebook_url',
           company_twitter_url                       text  PATH '$.company.twitter_url'
         )
       )
     ) AS jt
WHERE jt.experience_idx IS NOT NULL
  AND jt.company_pdl_id IS NOT NULL
