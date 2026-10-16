{#-
  ref.job_title_role — PDL canonical job-title role vocabulary.

  Mid-level title category ("software_engineer", "product_manager",
  etc). One row per distinct value of
  staging.pdl_person_experience_parsed.title_role.

  UNIQUE on name per ref.dbml.

  Surrogate id + timestamps: dbt-computed in the SELECT (V14 dropped
  the IDENTITY clause from `id`). See ADR-0008.

  Source-of-truth shape: modeling/dbml/ref.dbml block
  `ref.job_title_role`. DDL in V4__ref_baseline.sql +
  V14__ref_drop_identity_from_id.sql.
-#}

WITH distinct_roles AS (
  SELECT DISTINCT
    title_role AS name
  FROM {{ ref('pdl_person_experience_parsed') }}
  WHERE title_role IS NOT NULL AND title_role <> ''
)

SELECT
  ROW_NUMBER() OVER (ORDER BY name) AS id,
  name,
  now()                             AS timestamp_created,
  now()                             AS timestamp_modified
FROM distinct_roles
