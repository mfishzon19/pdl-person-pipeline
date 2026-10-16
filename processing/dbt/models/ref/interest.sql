{#-
  ref.interest — PDL interest vocabulary, deduped from the staging side.

  One row per distinct interest string observed in
  staging.pdl_person_parsed.interests (jsonb array of bare strings).

  Same shape as ref.skill. No UNIQUE on name. type is NULL.

  Surrogate id + timestamps: dbt-computed in the SELECT (V14 dropped
  the IDENTITY clause from `id`). See ADR-0008.

  Source-of-truth shape: modeling/dbml/ref.dbml block `ref.interest`.
  DDL in V4__ref_baseline.sql + V14__ref_drop_identity_from_id.sql.
-#}

WITH distinct_interests AS (
  SELECT
    interest AS name,
    NULL::text AS type
  FROM (
    SELECT DISTINCT jsonb_array_elements_text(interests) AS interest
    FROM {{ ref('pdl_person_parsed') }}
    WHERE interests IS NOT NULL AND jsonb_typeof(interests) = 'array'
  ) src
  WHERE interest IS NOT NULL AND interest <> ''
)

SELECT
  ROW_NUMBER() OVER (ORDER BY name) AS id,
  name,
  type,
  now()                             AS timestamp_created,
  now()                             AS timestamp_modified
FROM distinct_interests
