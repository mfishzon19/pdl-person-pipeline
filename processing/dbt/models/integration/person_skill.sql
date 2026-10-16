{#-
  integration.person_skill — Person × Skill junction (PDL).

  Pure junction (composite PK on person_id, skill_id). Sources from
  staging.pdl_person_unique.skills jsonb array.

  Unnest pattern: cross-join the jsonb array via
  jsonb_array_elements_text(), match each skill name against
  ref.skill.name (PDL skill strings are bare text — no LOWER()
  normalization at the ref level per ref.skill.sql).

  DISTINCT collapses duplicates within a person's skills[] array.

  Source-of-truth shape: modeling/dbml/integration.dbml block
  `integration.person_skill`. DDL in V6.
-#}

WITH person_skill_pairs AS (
  SELECT DISTINCT
    u.pdl_id     AS person_pdl_id,
    skill_name   AS name
  FROM {{ ref('pdl_person_unique') }} u,
       jsonb_array_elements_text(u.skills) AS skill_name
  WHERE u.skills IS NOT NULL
    AND jsonb_typeof(u.skills) = 'array'
    AND skill_name IS NOT NULL
    AND skill_name <> ''
)

SELECT
  p.id              AS person_id,
  s.id              AS skill_id,
  now()             AS timestamp_created,
  now()             AS timestamp_modified
FROM person_skill_pairs src
JOIN {{ ref('person') }} p ON p.pdl_id = src.person_pdl_id
JOIN {{ ref('skill') }}  s ON s.name   = src.name
