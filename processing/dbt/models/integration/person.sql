{#-
  integration.person — conformed Person (PDL).

  Reference integration model. Establishes the pattern the other
  integration models follow:

    1. Top-level staging table (pdl_person_unique) is the "anchor" — one
       row in produces one row out, ROW_NUMBER over its natural key.
    2. LEFT JOIN to sibling staging tables for additional scalars
       (pdl_person_addresses_unique for home address).
    3. LEFT JOIN through the ref.* dim chain for FK resolution
       (industry_id, location_id via the same 4-way chain ref.location
       itself uses internally).
    4. Surrogate id via ROW_NUMBER OVER (ORDER BY <natural_key>);
       dbt-computed per ADR-0010 (which extends ADR-0008's ref.*
       treatment to integration.*; applied in V20 — no IDENTITY at
       the DB level). **Identity-resolution work will swap this expression** for a
       JOIN to catalog.person_key_map.internal_person_id (per
       ADR-0007 + docs/requirements/01 §4.2). The ROW_NUMBER below is an
       intentional placeholder, not a final design choice.
       See ADR-0010 §"What this ADR is NOT — identity resolution".
    5. now() for timestamp_created / timestamp_modified.

  Address shape (V20):
  PDL person tier has no street-level data; the person_home row in
  pdl_person_addresses_unique emits only locality / postal_code / geo.
  We parse geo "lat,lng" into numeric latitude / longitude scalars on
  this table (there is no separate address table — docs/data_model/13
  §4.6).

  location_id resolution: mirrors ref/location.sql's own join chain —
  ref.country (name_lc) → ref.state_province (country_id + name_lc,
  LEFT) → ref.city (country_id + COALESCE(state_province_id) +
  name_lc, LEFT) → ref.metro (country_id + name_lc, LEFT) →
  ref.location (4-way composite via COALESCE, LEFT, null-safe). Every
  (country, region, locality, metro) tuple emitted by
  pdl_person_addresses_unique has a corresponding ref.location row by
  construction (ref/location.sql reads from the same staging table),
  so the final LEFT JOIN is null only when the home_address row had
  no country.

  COALESCE pattern (NOT `IS NOT DISTINCT FROM`) — required for the V5
  unique indexes on ref.city / ref.location to be planner-usable for
  this JOIN. V5 indexes use `COALESCE(<col>, 0)` expressions for
  null-safe uniqueness on nullable composite-FK keys; `IS NOT DISTINCT
  FROM` is logically equivalent but syntactically different, so the
  planner can't match it to the COALESCE-expression index and falls
  back to a hash join over the full ref.location set per outer row —
  orders of magnitude slower at full-delivery scale. Convention: every integration model JOINing to a
  ref.* composite-FK target uses COALESCE-on-both-sides for the
  nullable columns.

  Freshness signals (V17): job_last_changed / job_last_verified /
  location_last_updated arrive as `date` in staging; cast to
  timestamptz here to match the integration.person DBML shape.

  Source-of-truth shape: modeling/dbml/integration.dbml block
  `integration.person`. DDL in V6 + V16 + V17 + V20.
-#}

WITH home_address AS (
  SELECT
    person_pdl_id,
    locality,
    region,
    country,
    metro,
    postal_code,
    geo
  FROM {{ ref('pdl_person_addresses_unique') }}
  WHERE source_context = 'person_home'
    AND source_idx     = 0
),

home_address_resolved AS (
  SELECT
    h.person_pdl_id,
    h.postal_code,
    h.geo,
    c.id   AS country_id,
    sp.id  AS state_province_id,
    ci.id  AS city_id,
    m.id   AS metro_id
  FROM home_address h
  LEFT JOIN {{ ref('country') }} c
    ON c.name_lc = LOWER(h.country)
  LEFT JOIN {{ ref('state_province') }} sp
    ON sp.country_id = c.id
   AND sp.name_lc    = LOWER(h.region)
  LEFT JOIN {{ ref('city') }} ci
    ON ci.country_id                      = c.id
   AND COALESCE(ci.state_province_id, 0) = COALESCE(sp.id, 0)
   AND ci.name_lc                         = LOWER(h.locality)
  LEFT JOIN {{ ref('metro') }} m
    ON m.country_id = c.id
   AND m.name_lc    = LOWER(h.metro)
),

home_with_location AS (
  SELECT
    r.person_pdl_id,
    r.postal_code,
    r.geo,
    loc.id AS location_id
  FROM home_address_resolved r
  LEFT JOIN {{ ref('location') }} loc
    ON loc.country_id                      = r.country_id
   AND COALESCE(loc.state_province_id, 0) = COALESCE(r.state_province_id, 0)
   AND COALESCE(loc.city_id,           0) = COALESCE(r.city_id,           0)
   AND COALESCE(loc.metro_id,          0) = COALESCE(r.metro_id,          0)
)

SELECT
  ROW_NUMBER() OVER (ORDER BY p.pdl_id)         AS id,
  p.pdl_id,
  p.first_name,
  p.middle_name,
  p.middle_initial,
  p.last_name,
  p.last_initial,
  p.full_name,
  p.headline,
  p.summary,
  ind.id                                        AS industry_id,
  p.linkedin_id,
  p.linkedin_url,
  p.linkedin_username,
  h.location_id,
  CASE
    WHEN h.geo LIKE '%,%'
      THEN NULLIF(split_part(h.geo, ',', 1), '')::numeric(9,6)
    ELSE NULL::numeric(9,6)
  END                                           AS latitude,
  CASE
    WHEN h.geo LIKE '%,%'
      THEN NULLIF(split_part(h.geo, ',', 2), '')::numeric(9,6)
    ELSE NULL::numeric(9,6)
  END                                           AS longitude,
  h.postal_code,
  p.sex,
  p.work_email,
  p.job_last_changed::timestamptz               AS job_last_changed,
  p.job_last_verified::timestamptz              AS job_last_verified,
  p.location_last_updated::timestamptz          AS location_last_updated,
  now()                                         AS timestamp_created,
  now()                                         AS timestamp_modified
FROM {{ ref('pdl_person_unique') }} p
LEFT JOIN {{ ref('industry') }} ind
  ON ind.name = p.industry
LEFT JOIN home_with_location h
  ON h.person_pdl_id = p.pdl_id
