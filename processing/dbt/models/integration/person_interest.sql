{#-
  integration.person_interest — Person × Interest junction (PDL).

  Pure junction (composite PK on person_id, interest_id). Sources from
  staging.pdl_person_unique.interests jsonb array.

  Same pattern as integration.person_skill — unnest the jsonb array,
  join to ref.interest by bare name.

  Source-of-truth shape: modeling/dbml/integration.dbml block
  `integration.person_interest`. DDL in V6.
-#}

WITH person_interest_pairs AS (
  SELECT DISTINCT
    u.pdl_id        AS person_pdl_id,
    interest_name   AS name
  FROM {{ ref('pdl_person_unique') }} u,
       jsonb_array_elements_text(u.interests) AS interest_name
  WHERE u.interests IS NOT NULL
    AND jsonb_typeof(u.interests) = 'array'
    AND interest_name IS NOT NULL
    AND interest_name <> ''
)

SELECT
  p.id              AS person_id,
  i.id              AS interest_id,
  now()             AS timestamp_created,
  now()             AS timestamp_modified
FROM person_interest_pairs src
JOIN {{ ref('person') }}   p ON p.pdl_id = src.person_pdl_id
JOIN {{ ref('interest') }} i ON i.name   = src.name
