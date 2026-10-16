{#-
  integration.experience_industry — Experience × Industry junction
  (PDL).

  Pure junction (composite PK on experience_id, industry_id) +
  per-edge `source` text column recording which source attested the
  edge ('pdl').

  V27 simplified the JOIN-back to integration.experience: now uses
  (person_id, experience_idx) integer compare against V27's
  idx_experience_person_idx index. A 4-col natural-key COALESCE join
  back to integration.experience was too slow at full-delivery scale.

  Sources from pdl_person_experience_unique.company_industry (one value
  per experience). Hardcoded source='pdl' on every row.

  Source-of-truth shape: modeling/dbml/integration.dbml block
  `integration.experience_industry`. DDL in V6 + V16 (industry text →
  bigint FK on integration.company) + V26 (timestamps added).
-#}

SELECT DISTINCT
  e.id                                       AS experience_id,
  ind.id                                     AS industry_id,
  'pdl'                                      AS source,
  now()                                      AS timestamp_created,
  now()                                      AS timestamp_modified
FROM {{ ref('pdl_person_experience_unique') }} src
JOIN {{ ref('person') }}     p   ON p.pdl_id        = src.person_pdl_id
JOIN {{ ref('experience') }} e   ON e.person_id     = p.id
                                AND e.experience_idx = src.experience_idx
JOIN {{ ref('industry') }}   ind ON ind.name        = src.company_industry
WHERE src.company_industry IS NOT NULL
  AND src.company_industry <> ''
