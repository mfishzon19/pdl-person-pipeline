{#-
  integration.experience_location — Experience × Location junction (PDL).

  Pure junction (composite PK on experience_id, location_id). Sources from
  staging.pdl_person_addresses_unique with source_context='experience_company_hq'
  — the per-experience company HQ address row.

  JOIN-back strategy (V27): a 4-col natural-key COALESCE JOIN to
  integration.experience on (person_id, company_id, start_year, title) is
  too slow at full-delivery scale, so V27 added the experience_idx column
  + a (person_id, experience_idx) index on integration.experience. The JOIN
  is now two integer columns, index-friendly.

  Path:
    1. addresses_unique (source_context='experience_company_hq') gives one
       address row per (person_pdl_id, experience_idx=source_idx).
    2. Resolve location_id via the 4-way ref chain (country → state → city
       → metro → location) with the COALESCE pattern matching V5 expression
       indexes on ref.location.
    3. Resolve person_id via integration.person.pdl_id, then JOIN
       integration.experience by (person_id, experience_idx) — fast indexed
       lookup using V27's idx_experience_person_idx.

  Source-of-truth shape: modeling/dbml/integration.dbml block
  `integration.experience_location`. DDL in V6.
-#}

WITH experience_addresses AS (
  SELECT
    a.person_pdl_id,
    a.source_idx AS experience_idx,
    a.locality,
    a.region,
    a.country,
    a.metro
  FROM {{ ref('pdl_person_addresses_unique') }} a
  WHERE a.source_context = 'experience_company_hq'
),

resolved_location AS (
  SELECT
    x.person_pdl_id,
    x.experience_idx,
    c.id   AS country_id,
    sp.id  AS state_province_id,
    ci.id  AS city_id,
    m.id   AS metro_id
  FROM experience_addresses x
  LEFT JOIN {{ ref('country') }} c
    ON c.name_lc = LOWER(x.country)
  LEFT JOIN {{ ref('state_province') }} sp
    ON sp.country_id = c.id
   AND sp.name_lc    = LOWER(x.region)
  LEFT JOIN {{ ref('city') }} ci
    ON ci.country_id                      = c.id
   AND COALESCE(ci.state_province_id, 0) = COALESCE(sp.id, 0)
   AND ci.name_lc                        = LOWER(x.locality)
  LEFT JOIN {{ ref('metro') }} m
    ON m.country_id = c.id
   AND m.name_lc    = LOWER(x.metro)
)

SELECT DISTINCT
  e.id              AS experience_id,
  loc.id            AS location_id,
  now()             AS timestamp_created,
  now()             AS timestamp_modified
FROM resolved_location r
JOIN {{ ref('location') }} loc
  ON loc.country_id                      = r.country_id
 AND COALESCE(loc.state_province_id, 0) = COALESCE(r.state_province_id, 0)
 AND COALESCE(loc.city_id,           0) = COALESCE(r.city_id,           0)
 AND COALESCE(loc.metro_id,          0) = COALESCE(r.metro_id,          0)
JOIN {{ ref('person') }}     p ON p.pdl_id        = r.person_pdl_id
JOIN {{ ref('experience') }} e ON e.person_id     = p.id
                              AND e.experience_idx = r.experience_idx
