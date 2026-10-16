{#-
  ref.city — DISTINCT (country, region, locality) tuples from PDL
  address data.

  country_id NOT NULL (INNER JOIN to ref.country). state_province_id
  nullable — PDL often emits a locality without a region, so a LEFT
  JOIN to ref.state_province leaves it NULL in that case.

  The V5__ref_unique_indexes.sql COALESCE-based unique index on
  (country_id, COALESCE(state_province_id, 0), name_lc) allows multiple
  "nyc" rows: one per (country, region) combination including
  (country, NULL). Postgres can't express COALESCE in an inline UNIQUE
  constraint, hence the hand-authored sidecar index.

  LOWER() defensively on every join key + the inserted name_lc.

  Surrogate id + timestamps: dbt-computed in the SELECT (V14 dropped
  the IDENTITY clause from `id`). See ADR-0008.

  Source-of-truth shape: modeling/dbml/ref.dbml block `ref.city`.
  DDL in V4__ref_baseline.sql + V5__ref_unique_indexes.sql +
  V14__ref_drop_identity_from_id.sql.
-#}

WITH distinct_cities AS (
  SELECT DISTINCT
    c.id              AS country_id,
    sp.id             AS state_province_id,
    LOWER(a.locality) AS name_lc
  FROM {{ ref('pdl_person_addresses_unique') }} a
  JOIN      {{ ref('country') }}        c
    ON c.name_lc = LOWER(a.country)
  LEFT JOIN {{ ref('state_province') }} sp
    ON sp.country_id = c.id
    AND sp.name_lc   = LOWER(a.region)
  WHERE a.locality IS NOT NULL AND a.locality <> ''
)

SELECT
  ROW_NUMBER() OVER (
    ORDER BY country_id, COALESCE(state_province_id, 0), name_lc
  ) AS id,
  country_id,
  state_province_id,
  name_lc,
  now()  AS timestamp_created,
  now()  AS timestamp_modified
FROM distinct_cities
