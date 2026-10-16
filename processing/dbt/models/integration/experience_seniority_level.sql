{#-
  integration.experience_seniority_level — Experience × Seniority junction
  (PDL).

  Pure junction (composite PK on experience_id, seniority_level_id).
  Sources from staging.pdl_person_experience_unique.title_levels jsonb
  array — a title can map to multiple levels (e.g. "manager" + "director").

  V27 simplified the JOIN-back to integration.experience: now uses
  (person_id, experience_idx) integer compare against V27's
  idx_experience_person_idx index (see experience_location.sql for why
  the 4-col natural-key join was replaced).

  Source-of-truth shape: modeling/dbml/integration.dbml block
  `integration.experience_seniority_level`. DDL in V6.
-#}

SELECT DISTINCT
  e.id                                          AS experience_id,
  sl.id                                         AS seniority_level_id,
  now()                                         AS timestamp_created,
  now()                                         AS timestamp_modified
FROM {{ ref('pdl_person_experience_unique') }} src
CROSS JOIN LATERAL jsonb_array_elements_text(src.title_levels) AS level_name
JOIN {{ ref('person') }}          p  ON p.pdl_id        = src.person_pdl_id
JOIN {{ ref('experience') }}      e  ON e.person_id     = p.id
                                    AND e.experience_idx = src.experience_idx
JOIN {{ ref('seniority_level') }} sl ON sl.name         = level_name
WHERE src.title_levels IS NOT NULL
  AND jsonb_typeof(src.title_levels) = 'array'
  AND level_name IS NOT NULL
  AND level_name <> ''
