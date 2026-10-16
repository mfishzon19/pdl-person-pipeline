-- =============================================================================
-- DISCLAIMER — EXPLORATORY / R&D CONTEXT
--
-- This file is part of the cleansing R&D. It reads from the integration
-- schema for convenience (run it against a local database where a PDL
-- delivery has already been built through integration.*).
--
-- In the target cleansing design, this logic must be applied UPSTREAM — at the
-- per-source `_cleaned` staging tier (between `_unique` and `_staged`),
-- BEFORE integration.* is populated. Cleansing on top of integration is a
-- convenience for exploration; it inverts the intended data flow.
--
-- Design target: docs/design/21_cleansing_layer_design.md
-- =============================================================================


-- cleansing_rad.func_is_broken_pdl_company(text) ----------------------------
--
-- Returns TRUE when a company name is a broken PDL canonical — i.e., the
-- string is a job title, employment status, or generic placeholder that a
-- person typed into their LinkedIn "company" field instead of their actual
-- employer, and which PDL then canonicalized into one bogus company entity
-- with thousands of "employees".
--
-- Observed shape: a PDL company whose entire name is an occupation token
--   (e.g. name = '<occupation>', a small company's website, size = 11-50)
--   with thousands of person-experience rows attributed to it — obviously
--   impossible for an 11-50 company. See V1/V2 below for the full sweep.
--
-- Approach: normalize the input (lowercase, trim, strip trailing period)
-- then compare against a curated list of tokens that are ALWAYS bogus
-- when they're a company's entire name.
--
-- Categories in the token list:
--   - Occupations       (doctor, engineer, teacher, lawyer, ...)
--   - Roles             (manager, director, ceo, founder, partner, ...)
--   - Employment status (self-employed, freelance, retired, student, ...)
--   - Placeholders      (none, n/a, unknown, private, various, ...)
--
-- What this does NOT catch:
--   - Companies with legit but short names that happen to overlap (e.g. a
--     firm literally named "Founder") — accepted false-negative risk on the
--     legit side vs the large over-attribution risk on the bogus side. A
--     token is added only when no legit company uses it verbatim as its
--     full name.
--   - Broken canonicals whose PDL name is a longer garbage string (e.g.
--     "engineer at large company"). Those need a separate heuristic (size
--     vs experience-row ratio, etc.) — future filter.
--
-- Deployment notes:
--   - IMMUTABLE  — safe in expression indexes.
--   - STRICT     — NULL input returns NULL (treat NULL name as unknown,
--                   not broken — the caller decides).
-- ---------------------------------------------------------------------------

create or replace function cleansing_rad.func_is_broken_pdl_company(nm text)
  returns bool
  language sql
  immutable
  strict
as $$
  select regexp_replace(lower(trim(nm)), '\.$', '', 'g') = any(array[
    -- occupations
    'doctor', 'physician', 'nurse', 'dentist', 'therapist', 'psychiatrist', 'psychologist',
    'teacher', 'professor', 'tutor', 'educator', 'instructor',
    'engineer', 'developer', 'programmer', 'architect',
    'consultant', 'advisor', 'adviser', 'analyst', 'specialist', 'professional',
    'accountant', 'auditor', 'bookkeeper',
    'lawyer', 'attorney', 'counsel', 'counselor', 'paralegal',
    'writer', 'author', 'editor', 'journalist', 'blogger',
    'artist', 'photographer', 'designer', 'musician',
    'coach', 'trainer', 'mentor',
    'realtor', 'agent', 'broker', 'realtor associate',
    'chef', 'driver', 'salesperson', 'salesman', 'saleswoman',
    -- roles (bogus as a full company name)
    'manager', 'director', 'executive', 'officer', 'president', 'vice president',
    'ceo', 'cfo', 'cto', 'coo', 'chairman', 'chair',
    'founder', 'co-founder', 'cofounder', 'owner', 'co-owner', 'coowner',
    'partner', 'principal', 'associate',
    -- employment status
    'freelancer', 'freelance', 'contractor', 'entrepreneur', 'businessman', 'businesswoman',
    'self-employed', 'self employed', 'selfemployed', 'self employment',
    'unemployed', 'retired', 'looking for work', 'looking',
    'student', 'graduate', 'intern',
    'homemaker', 'housewife', 'stay at home mom', 'stay at home dad',
    'volunteer',
    -- placeholders / non-companies
    'none', 'n/a', 'na', 'not applicable', 'unknown', 'confidential',
    'private', 'private practice', 'private practise', 'personal', 'myself', 'me',
    'other', 'various', 'various clients', 'multiple', 'multiple companies',
    'home', 'work from home', 'own', 'own business', 'my company',
    '-', '--', '.', '...', 'null', 'test'
  ]);
$$;


-- PERF — partial index on the predicate ----------------------------------------
--
-- Without this, V5 seq-scans integration.company (millions of rows on a full
-- delivery) evaluating the predicate per row, which takes seconds. The function is IMMUTABLE so Postgres will honor
-- it in an index expression. Partial-index shape means the index only holds
-- the few hundred broken company ids — tiny, cheap to maintain, and turns V5+V6
-- into millisecond lookups.
--
-- R&D-only; not part of the DBML. When this rule moves to the
-- pipeline `_cleaned` staging tier, the equivalent expression index goes on
-- the source-side `_unique` table instead.

create index if not exists integration_company_broken_pdl_partial_idx
  on integration.company (id)
 where cleansing_rad.func_is_broken_pdl_company(name);


-- CHECK: predicate sanity on a spread of inputs
select input,
       cleansing_rad.func_is_broken_pdl_company(input) as is_broken
  from (values
    ('engineer'::text),                     --true — the core case
    ('Engineer'),                            --true — case-fold
    (' engineer '),                          --true — trim
    ('engineer.'),                           --true — trailing period strip
    ('self-employed'),                       --true
    ('N/A'),                                 --true
    ('Founder'),                             --true
    ('Acme Holdings Inc'),                   --false — real-looking company
    ('Globex Ltd'),                          --false — real-looking company
    ('Initech GmbH'),                        --false — real-looking company
    ('Founder & CEO'),                       --false — compound, not a pure role token
    ('Engineer at Large'),                   --false — compound
    (null)                                   --null (STRICT)
  ) t(input);


-- V1. Sweep — how many broken pdl_company rows exist, and how many
--     experience rows point at them?
select count(*)                                             as broken_company_rows,
       sum(exp_cnt)                                          as total_experience_rows,
       count(*) filter (where exp_cnt > 100)                as broken_high_impact,
       count(distinct case when exp_cnt > 100 then id end)  as _same_check
  from (
    select c.id,
           (select count(*) from integration.experience e where e.company_id = c.id) as exp_cnt
      from integration.company c
     where cleansing_rad.func_is_broken_pdl_company(c.name)
  ) x;


-- V2. Top 30 broken companies by experience row count — the offenders,
--     ranked by blast radius
select c.id                as company_id,
       c.pdl_company_id,
       c.name,
       c.website,
       c.size,
       c.source,
       (select count(*) from integration.experience e where e.company_id = c.id) as exp_rows
  from integration.company c
 where cleansing_rad.func_is_broken_pdl_company(c.name)
 order by exp_rows desc
 limit 30;


-- V3. Distinct persons affected — how many people would lose at least
--     one experience row to this filter?
select count(distinct e.person_id) as affected_persons
  from integration.experience e
  join integration.company    c on c.id = e.company_id
 where cleansing_rad.func_is_broken_pdl_company(c.name);


-- V4. Pattern-A apply — the experience rows to drop
select count(*) as experience_rows_to_drop
  from integration.experience e
  join integration.company    c on c.id = e.company_id
 where cleansing_rad.func_is_broken_pdl_company(c.name);


-- V5, V6 (delete-preview + DELETE templates) live in a separate script:
-- broken_pdl_company_apply.sql
