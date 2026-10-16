{#-
  integration.person_education — Person × School junction (PDL).

  Junction-with-attributes pattern (same shape as integration.experience).
  1:1 with staging.pdl_person_education_unique (minus rows whose person
  doesn't resolve).

  Sources:
    staging.pdl_person_education_unique  — 1 row per (person, school,
                                            start_year, degrees_text)
                                            natural key
    integration.person                    — INNER JOIN on pdl_id (NOT NULL FK)
    integration.school                    — LEFT JOIN on school_pdl_id
                                            (NULL when PDL emitted no
                                            school_pdl_id)

  Date precision (V26):
    start_year / end_year are int4 — PDL emits education[].start_date
    with year-only precision. V26 changed them from timestamptz so the
    target matches the source shape (mirrors V25's experience change).

  degrees/majors/minors stay jsonb (per-education arrays; no useful
  cross-entity grouping today — per docs/data_model/13 §4.3).

  Surrogate id via ROW_NUMBER OVER the staging natural key — matches the
  dedup UNIQUE constraint on pdl_person_education_unique
  (person_pdl_id, school_pdl_id, start_year, degrees_text). Postgres
  should use the existing constraint for an index-order scan.

  Person resolution — INNER JOIN to integration.person on pdl_id.
  Same alias-resolution caveat as integration.experience: rare
  multi-hop alias chains may drop education rows whose raw
  person_pdl_id was an alias. Acceptable for now.

  Source-of-truth shape: modeling/dbml/integration.dbml block
  `integration.person_education`. DDL in V6 + V16 + V20 + V26.
-#}

SELECT
  ROW_NUMBER() OVER (
    ORDER BY e.person_pdl_id, e.school_pdl_id, e.start_year, e.degrees_text
  )                                AS id,
  p.id                             AS person_id,
  s.id                             AS school_id,
  e.start_year,
  e.end_year,
  e.degrees,
  e.majors,
  e.minors,
  e.gpa,
  e.summary,
  now()                            AS timestamp_created,
  now()                            AS timestamp_modified
FROM {{ ref('pdl_person_education_unique') }} e
JOIN      {{ ref('person') }} p ON p.pdl_id    = e.person_pdl_id
LEFT JOIN {{ ref('school') }} s ON s.pdl_id    = e.school_pdl_id
