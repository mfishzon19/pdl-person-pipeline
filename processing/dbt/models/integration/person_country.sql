{#-
  integration.person_country — Person × Country junction (PDL).

  Pure junction (composite PK on person_id, country_id). Sources from
  staging.pdl_person_unique.countries jsonb array — the derived set of
  all countries associated with the person (distinct from
  integration.person.location_id which is the home address only).

  Unnest pattern: cross-join the jsonb array via
  jsonb_array_elements_text(), match each country name against
  ref.country.name_lc (lowercased per ref.country.sql convention).

  DISTINCT collapses duplicates within a person's countries[] array
  (PDL occasionally emits the same country twice in the array).
  Composite PK (person_id, country_id) is the final integrity check.

  Source-of-truth shape: modeling/dbml/integration.dbml block
  `integration.person_country`. DDL in V6.
-#}

WITH person_country_pairs AS (
  SELECT DISTINCT
    u.pdl_id           AS person_pdl_id,
    LOWER(country_name) AS country_name_lc
  FROM {{ ref('pdl_person_unique') }} u,
       jsonb_array_elements_text(u.countries) AS country_name
  WHERE u.countries IS NOT NULL
    AND jsonb_typeof(u.countries) = 'array'
    AND country_name IS NOT NULL
    AND country_name <> ''
)

SELECT
  p.id              AS person_id,
  c.id              AS country_id,
  now()             AS timestamp_created,
  now()             AS timestamp_modified
FROM person_country_pairs src
JOIN {{ ref('person') }}  p ON p.pdl_id  = src.person_pdl_id
JOIN {{ ref('country') }} c ON c.name_lc = src.country_name_lc
