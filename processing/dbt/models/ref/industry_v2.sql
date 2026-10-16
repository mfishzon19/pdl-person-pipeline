{#-
  ref.industry_v2 — PDL canonical industry v2 (expanded enum).

  PDL-sourced only. Industry v2 lives on the company
  sub-object — `company.industry_v2` — and does NOT appear at the
  person top level (unlike industry v1). Source is therefore
  pdl_person_companies_unique, not pdl_person_parsed.

  Surrogate id + timestamps: dbt-computed in the SELECT per ADR-0008
  (V14 dropped IDENTITY on ref.* `id`).

  Source-of-truth shape: modeling/dbml/ref.dbml block `ref.industry_v2`.
  DDL in V4__ref_baseline.sql + V14__ref_drop_identity_from_id.sql.

  No source_type column (unlike ref.industry). PDL is the sole source
  for industry v2; the discriminator wasn't necessary.
-#}

WITH distinct_industries_v2 AS (
  SELECT DISTINCT
    company_industry_v2 AS name
  FROM {{ ref('pdl_person_companies_unique') }}
  WHERE company_industry_v2 IS NOT NULL AND company_industry_v2 <> ''
)

SELECT
  ROW_NUMBER() OVER (ORDER BY name) AS id,
  name,
  now()                             AS timestamp_created,
  now()                             AS timestamp_modified
FROM distinct_industries_v2
