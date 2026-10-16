{#-
  ref.state_province — DISTINCT (country, region) tuples from PDL
  address data.

  country_id is NOT NULL per ref.dbml, so an INNER JOIN to ref.country
  filters out source rows whose country didn't resolve (effectively
  none, since country_id is the join target). iso_subdivision_code
  stays NULL — advisory, future seed.

  UNIQUE on (country_id, name_lc) per ref.dbml (V4__ref_baseline.sql).

  LOWER() defensively on both sides of the JOIN and on the inserted
  name_lc per the ref.dbml name_lc convention.

  Invariant: the INNER JOIN to ref.country cannot drop region rows in
  practice. ref.country is built from the SAME pdl_person_addresses_unique
  .country column with the same WHERE filter, so any country seen here
  also exists in ref.country. The JOIN is INNER (not LEFT) only to make
  country_id NOT NULL satisfiable.

  Surrogate id + timestamps: dbt-computed in the SELECT (V14 dropped
  the IDENTITY clause from `id`). See ADR-0008.

  Source-of-truth shape: modeling/dbml/ref.dbml block
  `ref.state_province`. DDL in V4__ref_baseline.sql +
  V14__ref_drop_identity_from_id.sql.
-#}

WITH distinct_state_provinces AS (
  SELECT DISTINCT
    c.id            AS country_id,
    LOWER(a.region) AS name_lc
  FROM {{ ref('pdl_person_addresses_unique') }} a
  JOIN {{ ref('country') }} c
    ON c.name_lc = LOWER(a.country)
  WHERE a.region IS NOT NULL AND a.region <> ''
)

SELECT
  ROW_NUMBER() OVER (ORDER BY country_id, name_lc) AS id,
  country_id,
  name_lc,
  NULL::text                                       AS iso_subdivision_code,
  now()                                            AS timestamp_created,
  now()                                            AS timestamp_modified
FROM distinct_state_provinces
