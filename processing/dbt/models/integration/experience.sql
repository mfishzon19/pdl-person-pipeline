{#-
  integration.experience — conformed Experience (PDL).

  Pattern category: "junction with attributes" — person × company × role
  with title, dates, summary. 1:1 with staging.pdl_person_experience_unique
  (minus rows whose person doesn't resolve; see below).

  Sources:
    staging.pdl_person_experience_unique  — 1 row per (person, company,
                                            start_year, title_name)
                                            natural key, alias-resolved
                                            via the staging _unique layer
    integration.person                    — INNER JOIN on pdl_id to
                                            resolve person_id (NOT NULL FK)
    integration.company                   — LEFT JOIN on pdl_company_id
                                            (NULL when PDL emitted no
                                            company.id)
    ref.job_title_class / _role / _subrole — LEFT JOIN per enum dim to
                                              resolve the 3 individual
                                              title FKs (V25)

  Title classification (V25):
    V6 baseline had a single composite FK job_title_classification_id →
    ref.job_title_classification(class, role, sub_role). PDL regularly
    emits class + role with a NULL sub_role, which the composite FK
    couldn't represent (ref required NOT NULL on all 3 cols). V25 replaced
    the composite with 3 independent FKs to ref.job_title_class / _role /
    _subrole. Each can be NULL independently; partial classifications
    are preserved.

    Three LEFT JOINs to ref dims by name (each ref table has UNIQUE on
    name; no COALESCE pattern needed since each lookup is single-column).

  Date precision (V25):
    start_year / end_year are int4 — PDL emits year-only precision.
    V25 changed them from timestamptz so the target matches the source
    shape (no make_date(year, 1, 1) padding).

  Surrogate id via ROW_NUMBER OVER the staging natural key — exactly
  matches the V19 dedup covering index on
  pdl_person_experience_parsed_dedup (person_pdl_id, company_pdl_id,
  start_year, title_name, ...). Postgres should use index-order scan
  for the ROW_NUMBER, no extra sort step.

  experience_idx (V27):
    Carried verbatim from staging.pdl_person_experience_unique.experience_idx.
    Combined with person_id, uniquely identifies each integration.experience
    row. Used as the JOIN key from per-experience junction models
    (integration.experience_location / _industry / _seniority_level) so they
    don't have to do a 4-col natural-key COALESCE join back to here.

  Person resolution — INNER JOIN to integration.person on pdl_id:
    staging.pdl_person_unique applies recursive alias resolution
    (catalog.pdl_id_aliases). Most experience.person_pdl_id values match
    directly; experiences whose raw person_pdl_id was merged into another
    id are dropped by the INNER JOIN — acceptable for now; could be
    tightened later by alias-resolving the experience side too.

  Source-of-truth shape: modeling/dbml/integration.dbml block
  `integration.experience`. DDL in V6 + V20 (IDENTITY drop) + V25.
-#}

SELECT
  ROW_NUMBER() OVER (
    ORDER BY e.person_pdl_id, e.company_pdl_id, e.start_year, e.title_name
  )                                AS id,
  p.id                             AS person_id,
  e.experience_idx,
  c.id                             AS company_id,
  e.start_year,
  e.end_year,
  e.title_name                     AS title,
  cls.id                           AS title_class_id,
  rl.id                            AS title_role_id,
  sr.id                            AS title_sub_role_id,
  e.is_primary,
  e.summary,
  now()                            AS timestamp_created,
  now()                            AS timestamp_modified
FROM {{ ref('pdl_person_experience_unique') }} e
JOIN      {{ ref('person') }}            p   ON p.pdl_id         = e.person_pdl_id
LEFT JOIN {{ ref('company') }}           c   ON c.pdl_company_id = e.company_pdl_id
LEFT JOIN {{ ref('job_title_class') }}   cls ON cls.name = e.title_class
LEFT JOIN {{ ref('job_title_role') }}    rl  ON rl.name  = e.title_role
LEFT JOIN {{ ref('job_title_subrole') }} sr  ON sr.name  = e.title_sub_role
