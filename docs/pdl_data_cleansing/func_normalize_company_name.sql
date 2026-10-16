-- =============================================================================
-- DISCLAIMER — EXPLORATORY / R&D CONTEXT
--
-- This file is part of the cleansing R&D. It reads from the integration
-- schema for convenience (run it against a local database where a PDL
-- delivery has already been built through integration.*).
--
-- In the target cleansing design, this logic must be applied UPSTREAM —
-- at the per-source `_cleaned` staging tier (between _unique and _staged),
-- BEFORE integration.* is populated. Cleansing on top of integration is a
-- convenience for exploration; it inverts the intended data flow.
--
-- Target design: docs/design/21_cleansing_layer_design.md
-- =============================================================================


-- cleansing_rad.func_normalize_company_name(text) ---------------------------
--
-- Normalizes company-name strings for dedup / JOIN comparison.
--   1. NFC-folds decomposed Unicode into precomposed form.
--   2. Replaces typographic punctuation with ASCII equivalents
--      (curly apostrophes/quotes → straight, en/em/horizontal dashes → hyphen,
--       standalone acute/grave → straight apostrophe).
--   3. Trims outer whitespace.
--   4. Collapses internal whitespace runs to a single space.
--
-- Does NOT (yet):
--   - Collapse suffix variants ("Inc." vs "Incorporated" vs "Corp." vs "LLC")
--     — that's a Class-D synonym-rollup concern (docs/design/21_cleansing_layer_design.md §3)
--   - Case-fold (company display casing preserved; comparison uses lower()
--     on the caller side when needed)
--
-- Scope: company.name / experience[].company.name. Deliberately NOT applied
--        to job_company_name — that column is redundant with the current
--        experience row's company and shouldn't be independently normalized.
--
-- Deployment notes:
--   - IMMUTABLE  — safe in generated columns and expression indexes.
--   - STRICT     — NULL input returns NULL.
--   - Cost       — same shape as func_normalize_person_name.
--
-- Placement:
--   - For exploration: run this file before any script that calls it.
--   - Long-term: a Flyway repeatable migration (R__func_*.sql; see
--     docs/design/21_cleansing_layer_design.md §5). Same body.
-- ---------------------------------------------------------------------------

create or replace function cleansing_rad.func_normalize_company_name(name text)
  returns text
  language sql
  immutable
  strict
as $$
  select regexp_replace(
           trim(
             translate(
               normalize(name, NFC),
               U&'\2018\2019\201A\201B\201C\201D\2013\2014\2015\00B4\0060',
                 '''''''''""---'''
             )
           ),
           '\s+', ' ', 'g'
         );
$$;


-- CHECK: sample inputs → normalized outputs
select
  original,
  cleansing_rad.func_normalize_company_name(original) as normalized
  from (values
    ('O’Malley Example Media'::text),               --curly apostrophe → straight
    ('Example Holdings — Cloud Division'),          --em-dash → hyphen
    ('  Acme   Corp  '),                            --whitespace collapse + trim
    ('L''Étoile Example'),                          --straight apostrophe left alone
    ('Café Example SA'),                            --already NFC — no change
    (normalize('Café Example SA', NFD)),           --NFD é (e + combining acute) → NFC
    (null)                                          --NULL → NULL (STRICT)
  ) t(original);

