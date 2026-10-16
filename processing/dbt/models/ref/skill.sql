{#-
  ref.skill — PDL skill vocabulary, deduped from the staging side.

  One row per distinct skill string observed in
  staging.pdl_person_parsed.skills (jsonb array of bare strings).

  No UNIQUE on name in ref.dbml — PDL skill strings are noisy and
  cross-source dedup is future work. DISTINCT in the subquery gives
  us one row per skill within this source.

  type: NULL — PDL doesn't ship a skill type at the array-element level.

  Surrogate id + timestamps: dbt-computed in the SELECT (V14 dropped
  the IDENTITY clause from `id`). See ADR-0008.

  Source-of-truth shape: modeling/dbml/ref.dbml block `ref.skill`. DDL
  in V4__ref_baseline.sql + V14__ref_drop_identity_from_id.sql.
-#}

WITH distinct_skills AS (
  SELECT
    skill AS name,
    NULL::text AS type
  FROM (
    SELECT DISTINCT jsonb_array_elements_text(skills) AS skill
    FROM {{ ref('pdl_person_parsed') }}
    WHERE skills IS NOT NULL AND jsonb_typeof(skills) = 'array'
  ) src
  WHERE skill IS NOT NULL AND skill <> ''
)

SELECT
  ROW_NUMBER() OVER (ORDER BY name) AS id,
  name,
  type,
  now()                             AS timestamp_created,
  now()                             AS timestamp_modified
FROM distinct_skills
