{#-
  integration.school — conformed School (PDL).

  Entity table, ~1:1 with staging.pdl_person_schools_unique.
  Patterned on integration.company — same shape (PDL school
  sub-object → entity table with location_id FK).

  Address shape:
    PDL emits education[].school.location with coarse-grain fields
    only — continent/country/region/locality (no street, no metro).
    school does NOT inline lat/long/postal/street scalars (no source);
    only location_id FK to ref.location.

  location_id resolution mirrors integration.company's 4-way ref chain
  via the COALESCE pattern (matches V5 expression indexes on
  ref.city / ref.location — see the COALESCE note in person.sql).
  ref.metro is joined for the chain shape but always resolves NULL
  for schools (PDL never emits metro at school grain).

  Schools have at most one address (docs/data_model/13 §4.4 + the
  schools_unique natural key is school_pdl_id alone). Address joins
  through pdl_person_education_unique to recover (school_pdl_id,
  school_location_*); GROUP BY + MIN handles the case where multiple
  education rows reference the same school with identical location.

  Surrogate id via ROW_NUMBER OVER (ORDER BY pdl_id) — same pattern as
  integration.person / integration.company (ADR-0010).

  Source-of-truth shape: modeling/dbml/integration.dbml block
  `integration.school`. DDL in V6 + V16 + V20.
-#}

WITH school_address_dedup AS (
  -- One row per school. MIN() aggregator picks one value per column;
  -- in practice school location is identical across
  -- education rows referencing the same school_pdl_id (mirrors
  -- integration.company.sql's company-address assumption).
  SELECT
    e.school_pdl_id,
    MIN(e.school_location_country)   AS country,
    MIN(e.school_location_region)    AS region,
    MIN(e.school_location_locality)  AS locality
  FROM {{ ref('pdl_person_education_unique') }} e
  WHERE e.school_pdl_id IS NOT NULL
  GROUP BY e.school_pdl_id
),

resolved_location AS (
  -- 4-way ref chain. ref.metro joined for shape consistency but
  -- always resolves NULL for schools (no PDL metro at school grain).
  -- COALESCE pattern matching V5 expression indexes on ref.city /
  -- ref.location.
  SELECT
    d.school_pdl_id,
    c.id   AS country_id,
    sp.id  AS state_province_id,
    ci.id  AS city_id,
    NULL::bigint AS metro_id
  FROM school_address_dedup d
  LEFT JOIN {{ ref('country') }} c
    ON c.name_lc = LOWER(d.country)
  LEFT JOIN {{ ref('state_province') }} sp
    ON sp.country_id = c.id
   AND sp.name_lc    = LOWER(d.region)
  LEFT JOIN {{ ref('city') }} ci
    ON ci.country_id                      = c.id
   AND COALESCE(ci.state_province_id, 0) = COALESCE(sp.id, 0)
   AND ci.name_lc                        = LOWER(d.locality)
),

school_with_location AS (
  SELECT
    r.school_pdl_id,
    loc.id AS location_id
  FROM resolved_location r
  LEFT JOIN {{ ref('location') }} loc
    ON loc.country_id                      = r.country_id
   AND COALESCE(loc.state_province_id, 0) = COALESCE(r.state_province_id, 0)
   AND COALESCE(loc.city_id,           0) = COALESCE(r.city_id,           0)
   AND COALESCE(loc.metro_id,          0) = COALESCE(r.metro_id,          0)
)

SELECT
  ROW_NUMBER() OVER (ORDER BY s.school_pdl_id) AS id,
  s.school_pdl_id                              AS pdl_id,
  s.school_name                                AS name,
  s.school_domain                              AS domain,
  s.school_type                                AS type,
  s.school_website                             AS website,
  s.school_linkedin_id                         AS linkedin_id,
  s.school_linkedin_url                        AS linkedin_url,
  s.school_facebook_url                        AS facebook_url,
  s.school_twitter_url                         AS twitter_url,
  l.location_id,
  now()                                        AS timestamp_created,
  now()                                        AS timestamp_modified
FROM {{ ref('pdl_person_schools_unique') }} s
LEFT JOIN school_with_location l
  ON l.school_pdl_id = s.school_pdl_id
WHERE s.school_pdl_id IS NOT NULL
