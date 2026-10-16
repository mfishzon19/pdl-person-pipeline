{#-
  integration.company — conformed Company (PDL, 3-source merge).

  Three sources funnel into one single-pass SELECT (docs/design/18_pdl_api_generic_caller.md, docs/data_model/08
  §6.3-§6.4):

    1. person.experience.company  — staging.pdl_person_companies_unique,
       the baseline: every company seen on a person (12 shared scalars +
       location).
    2. PDL Company Enrichment     — staging.pdl_api_company_parsed, the
       (much smaller) enriched subset; wins on shared scalars via COALESCE
       and populates all enrichment-only scalars + 8 jsonb columns.
    3. affiliated_entities[] stubs — orphan companies referenced by an
       enriched company's affiliated_entities[] but present in neither of
       the above. They land as stub rows (only pdl_company_id + name +
       source populated) so the company_affiliation INNER JOINs never drop
       edges (docs/data_model/08 §6.4).

  source (3-value enum) is CASE at SELECT time — highest fidelity wins:
    enrichment > person_experience > affiliation_stub (docs/data_model/08 §6.3).

  Anchor: all distinct pdl_company_ids across person.experience +
  affiliated_entities[], UNION ALL + GROUP BY (avoids the implicit sort of
  UNION). Enrichment ids are a subset of person.experience so they add no
  new anchor rows (docs/data_model/08 §6.3). ROW_NUMBER OVER (ORDER BY pdl_company_id)
  computes the surrogate id (ADR-0008/0010) — output arrives id-ordered so
  PK insertion is append-only.

  Note on the person source: docs/design/18_pdl_api_generic_caller.md sketches the anchor against
  staging.pdl_person_experience_unique; this model reads the company-grain
  staging.pdl_person_companies_unique instead (1 row per company_pdl_id) so
  the person LEFT JOIN can't fan out — same company universe.

  immediate_parent_id / ultimate_parent_id: PDL emits immediate_parent /
  ultimate_parent as text scalars (the parent's pdl_company_id, not nested
  objects — docs/data_model/08 §7). Resolved to the parent's surrogate id via a
  LEFT JOIN back to the same anchor id map; NULL when the parent isn't in
  our set. Populated only on the minority of enriched companies that have
  a parent (docs/data_model/08 §4.1).

  Location (docs/data_model/08 §4.1): 4-way ref chain resolved from
  COALESCE(enrichment.location.*, person_experience.company_location.*).
  latitude/longitude parsed inline from the COALESCEd geo string (V24
  inlined the address scalars onto integration.company). person-side address recovered by joining
  pdl_person_addresses_unique (experience_company_hq context) through
  pdl_person_experience_unique to get company_pdl_id.

  fetched_at: enrichment rows carry the actual API call time
  (staging.called_at); non-enriched + stub rows get the pipeline run
  timestamp. COALESCE(enr.called_at, now()).

  Source-of-truth shape: modeling/dbml/integration.dbml block
  `integration.company`. DDL in V28. on_schema_change='fail' enforces this
  SELECT matches the table column-for-column.
-#}

WITH affiliated_flat AS (
  -- Every affiliated_entities[] element, tagged with the parent that
  -- carried it (for the earliest-parent display_name tiebreak below).
  SELECT
    e.elem->>'affiliated_id' AS pdl_company_id,
    e.elem->>'display_name'  AS display_name,
    c.pdl_company_id         AS parent_pdl_company_id
  FROM {{ ref('pdl_api_company_parsed') }} c,
       jsonb_array_elements(c.affiliated_entities) AS e(elem)
  WHERE e.elem->>'affiliated_id' IS NOT NULL
    AND e.elem->>'affiliated_id' <> ''
),

affiliated_names AS (
  -- Earliest-parent display_name wins: DISTINCT ON + ORDER BY
  -- parent_pdl_company_id is a deterministic, provenance-informed tiebreak
  -- (the display_name from the lowest-id parent that referenced this
  -- affiliate). MIN(display_name) would also be deterministic but picks by
  -- string order, not provenance — so it can't preserve first-seen-parent
  -- semantics (docs/design/18_pdl_api_generic_caller.md).
  SELECT DISTINCT ON (pdl_company_id)
    pdl_company_id,
    display_name
  FROM affiliated_flat
  ORDER BY pdl_company_id, parent_pdl_company_id
),

anchor AS (
  -- All distinct pdl_company_ids + the surrogate id. UNION ALL + GROUP BY
  -- (not UNION — avoids the implicit sort). One place computes id so the
  -- self-referential parent LEFT JOIN below stays consistent with it.
  SELECT
    pdl_company_id,
    ROW_NUMBER() OVER (ORDER BY pdl_company_id) AS id
  FROM (
    SELECT company_pdl_id AS pdl_company_id
    FROM {{ ref('pdl_person_companies_unique') }}
    WHERE company_pdl_id IS NOT NULL
    UNION ALL
    SELECT pdl_company_id FROM affiliated_flat
  ) src
  GROUP BY pdl_company_id
),

company_addresses_dedup AS (
  -- person.experience company HQ address, one row per company. MIN() is an
  -- arbitrary aggregator — safe because all rows per company_pdl_id carry
  -- the same HQ address in practice (docs/data_model/08 §6). HashAggregate,
  -- no sort.
  SELECT
    e.company_pdl_id,
    MIN(a.locality)       AS locality,
    MIN(a.region)         AS region,
    MIN(a.country)        AS country,
    MIN(a.metro)          AS metro,
    MIN(a.street_address) AS street_address,
    MIN(a.address_line_2) AS address_line_2,
    MIN(a.postal_code)    AS postal_code,
    MIN(a.geo)            AS geo
  FROM {{ ref('pdl_person_addresses_unique') }} a
  JOIN {{ ref('pdl_person_experience_unique') }} e
    ON e.person_pdl_id  = a.person_pdl_id
   AND e.experience_idx = a.source_idx
  WHERE a.source_context  = 'experience_company_hq'
    AND e.company_pdl_id IS NOT NULL
  GROUP BY e.company_pdl_id
),

location_raw AS (
  -- Per anchor company: COALESCE the raw location components,
  -- enrichment winning over person.experience (docs/data_model/08 §4.1).
  SELECT
    a.pdl_company_id,
    COALESCE(enr.location_locality,       pa.locality)       AS locality,
    COALESCE(enr.location_region,         pa.region)         AS region,
    COALESCE(enr.location_country,        pa.country)         AS country,
    COALESCE(enr.location_metro,          pa.metro)          AS metro,
    COALESCE(enr.location_street_address, pa.street_address) AS street_address,
    COALESCE(enr.location_address_line_2, pa.address_line_2) AS address_line_2,
    COALESCE(enr.location_postal_code,    pa.postal_code)    AS postal_code,
    COALESCE(enr.location_geo,            pa.geo)            AS geo
  FROM anchor a
  LEFT JOIN {{ ref('pdl_api_company_parsed') }} enr
    ON enr.pdl_company_id = a.pdl_company_id
  LEFT JOIN company_addresses_dedup pa
    ON pa.company_pdl_id = a.pdl_company_id
),

resolved_location AS (
  -- 4-way ref chain → country/state/city/metro integer FKs. Same
  -- COALESCE-matching pattern as V5 expression indexes on ref.city /
  -- ref.location.
  SELECT
    lr.pdl_company_id,
    lr.street_address, lr.address_line_2, lr.postal_code, lr.geo,
    co.id  AS country_id,
    sp.id  AS state_province_id,
    ci.id  AS city_id,
    m.id   AS metro_id
  FROM location_raw lr
  LEFT JOIN {{ ref('country') }} co
    ON co.name_lc = LOWER(lr.country)
  LEFT JOIN {{ ref('state_province') }} sp
    ON sp.country_id = co.id
   AND sp.name_lc    = LOWER(lr.region)
  LEFT JOIN {{ ref('city') }} ci
    ON ci.country_id                      = co.id
   AND COALESCE(ci.state_province_id, 0) = COALESCE(sp.id, 0)
   AND ci.name_lc                        = LOWER(lr.locality)
  LEFT JOIN {{ ref('metro') }} m
    ON m.country_id = co.id
   AND m.name_lc    = LOWER(lr.metro)
),

company_with_address AS (
  -- Final location resolution: location_id + inline lat/long/postal/street.
  SELECT
    r.pdl_company_id,
    loc.id            AS location_id,
    r.street_address,
    r.address_line_2,
    r.postal_code,
    CASE
      WHEN r.geo LIKE '%,%'
        THEN NULLIF(split_part(r.geo, ',', 1), '')::numeric(9,6)
      ELSE NULL::numeric(9,6)
    END               AS latitude,
    CASE
      WHEN r.geo LIKE '%,%'
        THEN NULLIF(split_part(r.geo, ',', 2), '')::numeric(9,6)
      ELSE NULL::numeric(9,6)
    END               AS longitude
  FROM resolved_location r
  LEFT JOIN {{ ref('location') }} loc
    ON loc.country_id                      = r.country_id
   AND COALESCE(loc.state_province_id, 0) = COALESCE(r.state_province_id, 0)
   AND COALESCE(loc.city_id,           0) = COALESCE(r.city_id,           0)
   AND COALESCE(loc.metro_id,          0) = COALESCE(r.metro_id,          0)
)

SELECT
  a.id,
  a.pdl_company_id,
  CASE
    WHEN enr.pdl_company_id IS NOT NULL THEN 'enrichment'
    WHEN pe.company_pdl_id  IS NOT NULL THEN 'person_experience'
    ELSE 'affiliation_stub'
  END                                                     AS source,

  -- Shared scalars — enrichment wins via COALESCE, person.experience
  -- fallback; name additionally falls back to the affiliated display_name
  -- (the only value a stub carries).
  COALESCE(enr.name,   pe.company_name, aff.display_name) AS name,
  COALESCE(enr.size,   pe.company_size)                   AS size,
  COALESCE(enr.founded, pe.company_founded)::smallint     AS founded,
  ind.id                                                  AS industry_id,
  indv2.id                                                AS industry_v2_id,
  COALESCE(enr.type,         pe.company_type)             AS type,
  COALESCE(enr.website,      pe.company_website)          AS website,
  COALESCE(enr.linkedin_id,  pe.company_linkedin_id)      AS linkedin_id,
  COALESCE(enr.linkedin_url, pe.company_linkedin_url)     AS linkedin_url,
  COALESCE(enr.facebook_url, pe.company_facebook_url)     AS facebook_url,
  COALESCE(enr.twitter_url,  pe.company_twitter_url)      AS twitter_url,
  COALESCE(enr.ticker,       pe.company_ticker)           AS ticker,

  -- Enrichment-only scalars (NULL for person_experience + stub rows)
  enr.display_name,
  enr.linkedin_slug,
  enr.mic_exchange,
  enr.summary,
  enr.headline,
  enr.employee_count,
  enr.inferred_revenue,
  ip.id                                                   AS immediate_parent_id,
  up.id                                                   AS ultimate_parent_id,
  enr.total_funding_raised,
  enr.latest_funding_stage,
  enr.last_funding_date,
  enr.number_funding_rounds,
  enr.dataset_version,
  enr.likelihood,

  -- Multi-valued enrichment (8 jsonb cols, enrichment-only) — V28
  enr.naics                     AS naics_codes,
  enr.sic                       AS sic_codes,
  enr.tags,
  enr.alternative_names,
  enr.alternative_domains,
  enr.funding_stages,
  enr.employee_count_by_country,
  enr.profiles,

  -- Common location (both sources via COALESCE; V24 inline scalars)
  h.location_id,
  h.latitude,
  h.longitude,
  h.postal_code,
  h.street_address,
  h.address_line_2,

  COALESCE(enr.called_at, now())                          AS fetched_at,
  now()                                                   AS timestamp_created,
  now()                                                   AS timestamp_modified
FROM anchor a
LEFT JOIN {{ ref('pdl_api_company_parsed') }}      enr ON enr.pdl_company_id = a.pdl_company_id
LEFT JOIN {{ ref('pdl_person_companies_unique') }} pe  ON pe.company_pdl_id  = a.pdl_company_id
LEFT JOIN affiliated_names                         aff ON aff.pdl_company_id = a.pdl_company_id
LEFT JOIN company_with_address                     h   ON h.pdl_company_id   = a.pdl_company_id
LEFT JOIN {{ ref('industry') }}    ind   ON ind.name   = COALESCE(enr.industry, pe.company_industry)
LEFT JOIN {{ ref('industry_v2') }} indv2 ON indv2.name = pe.company_industry_v2
LEFT JOIN anchor ip ON ip.pdl_company_id = enr.immediate_parent
LEFT JOIN anchor up ON up.pdl_company_id = enr.ultimate_parent
