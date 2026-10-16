{#-
  integration.person_location — Person × Location junction (PDL).

  Pure junction (composite PK on person_id, location_id). Sources from
  staging.pdl_person_unique.location_names[] — the "all locations
  associated with this person" array PDL emits.

  Each location_names[] entry is a comma-separated string like:
    "Buffalo, New York, United States"   (city, region, country)
    "California, United States"           (region, country)
    "United States"                       (country only)

  Parse: split on ',\s*', take the rightmost segments as country,
  region, city. metro stays NULL (PDL location_names[] doesn't carry
  metro — metro lives only on the structured pdl_person_addresses_unique
  rows). Resolve to ref.location via the standard 4-way chain.

  Distinct from:
    - integration.person.location_id — the person's HOME address only
      (1 location, sourced from pdl_person_addresses_unique with
      source_context='person_home').
    - integration.experience_location — work HQ locations sourced from
      addresses_unique with source_context='experience_company_hq'.

  Some overlap is expected (home location often appears in
  location_names[] too); DISTINCT on (person_id, location_id) handles
  that automatically.

  Source-of-truth shape: modeling/dbml/integration.dbml block
  `integration.person_location`. DDL in V6.
-#}

WITH unnested AS (
  SELECT
    u.pdl_id AS person_pdl_id,
    location_name
  FROM {{ ref('pdl_person_unique') }} u,
       jsonb_array_elements_text(u.location_names) AS location_name
  WHERE u.location_names IS NOT NULL
    AND jsonb_typeof(u.location_names) = 'array'
    AND location_name IS NOT NULL
    AND TRIM(location_name) <> ''
),

split_parts AS (
  SELECT
    person_pdl_id,
    location_name,
    regexp_split_to_array(LOWER(location_name), '\s*,\s*') AS parts
  FROM unnested
),

parsed AS (
  -- Right-align the parts: rightmost = country, then region, then city.
  -- Strings shorter than 3 parts yield NULL for the missing positions.
  SELECT
    person_pdl_id,
    NULLIF(TRIM(parts[array_length(parts, 1)]),     '') AS country_name_lc,
    CASE WHEN array_length(parts, 1) >= 2
         THEN NULLIF(TRIM(parts[array_length(parts, 1) - 1]), '') END AS region_name_lc,
    CASE WHEN array_length(parts, 1) >= 3
         THEN NULLIF(TRIM(parts[array_length(parts, 1) - 2]), '') END AS city_name_lc
  FROM split_parts
  WHERE array_length(parts, 1) >= 1
),

resolved AS (
  SELECT
    p.person_pdl_id,
    c.id   AS country_id,
    sp.id  AS state_province_id,
    ci.id  AS city_id
  FROM parsed p
  JOIN      {{ ref('country') }}        c  ON c.name_lc = p.country_name_lc
  LEFT JOIN {{ ref('state_province') }} sp ON sp.country_id = c.id
                                          AND sp.name_lc    = p.region_name_lc
  LEFT JOIN {{ ref('city') }}           ci ON ci.country_id                      = c.id
                                          AND COALESCE(ci.state_province_id, 0) = COALESCE(sp.id, 0)
                                          AND ci.name_lc                        = p.city_name_lc
)

SELECT DISTINCT
  per.id            AS person_id,
  loc.id            AS location_id,
  now()             AS timestamp_created,
  now()             AS timestamp_modified
FROM resolved r
JOIN {{ ref('person') }}   per ON per.pdl_id = r.person_pdl_id
JOIN {{ ref('location') }} loc
  ON loc.country_id                      = r.country_id
 AND COALESCE(loc.state_province_id, 0) = COALESCE(r.state_province_id, 0)
 AND COALESCE(loc.city_id,           0) = COALESCE(r.city_id,           0)
 AND COALESCE(loc.metro_id,          0) = 0  -- COALESCE form matches V5 expression index; IS NULL doesn't
