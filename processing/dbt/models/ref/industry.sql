{#-
  ref.industry — PDL canonical industry vocabulary.

  One row per distinct industry string observed in
  staging.pdl_person_parsed.industry (scalar text). UNIQUE on name
  per ref.dbml.

  source_type is hardcoded to 'pdl'.

  Surrogate id + timestamps: dbt-computed in the SELECT (V14 dropped
  the IDENTITY clause from `id`). See ADR-0008.

  Source-of-truth shape: modeling/dbml/ref.dbml block `ref.industry`.
  DDL in V4__ref_baseline.sql + V14__ref_drop_identity_from_id.sql.

  On widening: a UNION over pdl_person_companies_unique.company_industry +
  pdl_api_company_parsed.industry (to catch company-side values not seen
  at the person level) is unnecessary today — PDL uses ONE canonical
  industry taxonomy across person, job_company, experience.company and
  enrichment fields. Widening would only be a defensive hedge if PDL's
  vocabulary ever diverged across fields. Leave as person-only for now.
-#}

WITH distinct_industries AS (
  SELECT DISTINCT
    industry AS name,
    'pdl'    AS source_type
  FROM {{ ref('pdl_person_parsed') }}
  WHERE industry IS NOT NULL AND industry <> ''
)

SELECT
  ROW_NUMBER() OVER (ORDER BY name) AS id,
  name,
  source_type,
  now()                             AS timestamp_created,
  now()                             AS timestamp_modified
FROM distinct_industries
