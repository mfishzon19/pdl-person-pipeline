{#-
  ref.job_title_subrole — PDL canonical job-title sub-role vocabulary.

  Most-specific title category ("backend_engineer", "data_engineer",
  etc). One row per distinct value of
  staging.pdl_person_experience_parsed.title_sub_role.

  UNIQUE on name per ref.dbml.

  Surrogate id + timestamps: dbt-computed in the SELECT (V14 dropped
  the IDENTITY clause from `id`). See ADR-0008.

  Source-of-truth shape: modeling/dbml/ref.dbml block
  `ref.job_title_subrole`. DDL in V4__ref_baseline.sql +
  V14__ref_drop_identity_from_id.sql.
-#}

WITH distinct_subroles AS (
  SELECT DISTINCT
    title_sub_role AS name
  FROM {{ ref('pdl_person_experience_parsed') }}
  WHERE title_sub_role IS NOT NULL AND title_sub_role <> ''
)

SELECT
  ROW_NUMBER() OVER (ORDER BY name) AS id,
  name,
  now()                             AS timestamp_created,
  now()                             AS timestamp_modified
FROM distinct_subroles
