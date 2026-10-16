{#-
  ref.seniority_level — PDL canonical seniority vocabulary.

  Sourced from staging.pdl_person_experience_parsed.title_levels (jsonb
  array of bare strings: "manager", "director", "cxo", "senior",
  "partner", etc). One person/experience can map to multiple levels —
  the M:N relation lives at integration.experience_seniority_level.

  UNIQUE on name per ref.dbml.

  Surrogate id + timestamps: dbt-computed in the SELECT (V14 dropped
  the IDENTITY clause from `id`). See ADR-0008.

  Source-of-truth shape: modeling/dbml/ref.dbml block
  `ref.seniority_level`. DDL in V4__ref_baseline.sql +
  V14__ref_drop_identity_from_id.sql.
-#}

WITH distinct_levels AS (
  SELECT DISTINCT
    level AS name
  FROM (
    SELECT jsonb_array_elements_text(title_levels) AS level
    FROM {{ ref('pdl_person_experience_parsed') }}
    WHERE title_levels IS NOT NULL AND jsonb_typeof(title_levels) = 'array'
  ) src
  WHERE level IS NOT NULL AND level <> ''
)

SELECT
  ROW_NUMBER() OVER (ORDER BY name) AS id,
  name,
  now()                             AS timestamp_created,
  now()                             AS timestamp_modified
FROM distinct_levels
