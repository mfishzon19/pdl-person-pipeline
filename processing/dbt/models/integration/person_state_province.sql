{#-
  integration.person_state_province — Person × State/Province junction
  (PDL).

  Pure junction (composite PK on person_id, state_province_id). Sources from
  staging.pdl_person_unique.regions jsonb array.

  PDL emits each regions[] entry as a comma-separated tuple with a
  trailing country qualifier, e.g.:

    "california, united states"
    "england, united kingdom"
    "maharashtra, india"

  Real deliveries consistently follow this 2-part shape.

  Resolution: split on ',\s*', take parts[1] as region name + parts[2] as
  country name. Join to ref.country by name_lc, then ref.state_province
  by (country_id, name_lc). Composite-key join means the same region
  name in different countries resolves correctly — no lowest-id
  fallback needed.

  Source-of-truth shape: modeling/dbml/integration.dbml block
  `integration.person_state_province`. DDL in V6.
-#}

WITH person_region_pairs AS (
  SELECT DISTINCT
    u.pdl_id              AS person_pdl_id,
    LOWER(TRIM(parts[1])) AS region_name_lc,
    LOWER(TRIM(parts[2])) AS country_name_lc
  FROM {{ ref('pdl_person_unique') }} u,
       jsonb_array_elements_text(u.regions) AS region_str,
       LATERAL regexp_split_to_array(region_str, '\s*,\s*') AS parts
  WHERE u.regions IS NOT NULL
    AND jsonb_typeof(u.regions) = 'array'
    AND TRIM(region_str) <> ''
    AND array_length(parts, 1) >= 2
)

SELECT
  p.id              AS person_id,
  sp.id             AS state_province_id,
  now()             AS timestamp_created,
  now()             AS timestamp_modified
FROM person_region_pairs src
JOIN {{ ref('person') }}         p  ON p.pdl_id      = src.person_pdl_id
JOIN {{ ref('country') }}        c  ON c.name_lc     = src.country_name_lc
JOIN {{ ref('state_province') }} sp ON sp.country_id = c.id
                                    AND sp.name_lc   = src.region_name_lc
