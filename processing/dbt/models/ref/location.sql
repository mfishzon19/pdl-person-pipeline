{#-
  ref.location — composite-FK junction. One row per distinct
  (country, state_province, city, metro) tuple PDL emits.

  country_id NOT NULL (INNER JOIN to ref.country). state_province_id /
  city_id / metro_id nullable — PDL frequently emits an address with
  just (country, locality) and no region, so the parent FKs LEFT JOIN.

  COALESCE-on-both-sides on the city join's state_province_id is the
  null-safe equality form: an address with no region must match the
  city row whose state_province_id IS NULL, not a city row under some
  other state. Plain `=` would treat NULL = NULL as unknown and drop
  the match; `IS NOT DISTINCT FROM` is semantically equivalent but
  doesn't match the V5 expression index, so the planner can't use it.

  The V5__ref_unique_indexes.sql COALESCE-based unique indexes use the
  same `COALESCE(<col>, 0)` expressions on ref.city
  (country_id, COALESCE(state_province_id, 0), name_lc) and on
  ref.location (country_id, COALESCE(state_province_id, 0),
   COALESCE(city_id, 0), COALESCE(metro_id, 0)) — keying the NULL
  combinations uniquely AND letting downstream JOINs use the index
  when they mirror the expression syntactically. Convention shared
  with every integration model JOINing to a ref.* composite-FK target.

  LOWER() defensively on every join key.

  Surrogate id + timestamps: dbt-computed in the SELECT (V14 dropped
  the IDENTITY clause from `id`). See ADR-0008.

  Source-of-truth shape: modeling/dbml/ref.dbml block `ref.location`.
  DDL in V4__ref_baseline.sql + V5__ref_unique_indexes.sql +
  V14__ref_drop_identity_from_id.sql.
-#}

WITH distinct_locations AS (
  SELECT DISTINCT
    c.id   AS country_id,
    sp.id  AS state_province_id,
    ci.id  AS city_id,
    m.id   AS metro_id
  FROM {{ ref('pdl_person_addresses_unique') }} a
  JOIN      {{ ref('country') }}        c
    ON c.name_lc = LOWER(a.country)
  LEFT JOIN {{ ref('state_province') }} sp
    ON sp.country_id = c.id
    AND sp.name_lc   = LOWER(a.region)
  LEFT JOIN {{ ref('city') }} ci
    ON ci.country_id                      = c.id
    AND COALESCE(ci.state_province_id, 0) = COALESCE(sp.id, 0)
    AND ci.name_lc                        = LOWER(a.locality)
  LEFT JOIN {{ ref('metro') }} m
    ON m.country_id = c.id
    AND m.name_lc   = LOWER(a.metro)
  WHERE a.country IS NOT NULL AND a.country <> ''
)

SELECT
  ROW_NUMBER() OVER (
    ORDER BY country_id,
             COALESCE(state_province_id, 0),
             COALESCE(city_id, 0),
             COALESCE(metro_id, 0)
  ) AS id,
  country_id,
  state_province_id,
  city_id,
  metro_id,
  now()  AS timestamp_created,
  now()  AS timestamp_modified
FROM distinct_locations
