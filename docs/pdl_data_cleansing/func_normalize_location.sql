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


-- cleansing_rad.func_normalize_location(text) -------------------------------
--
-- Normalizes location-name strings (city / region / metro / country display
-- forms) for dedup / JOIN comparison.
--   1. NFC-folds decomposed Unicode into precomposed form.
--      Biggest win here — accented city names ("São Paulo", "Zürich", "Málaga")
--      arrive in NFD form from some upstream sources; NFC collapses them.
--   2. Replaces typographic punctuation with ASCII equivalents
--      (curly apostrophes/quotes → straight, en/em/horizontal dashes → hyphen,
--       standalone acute/grave → straight apostrophe).
--   3. Trims outer whitespace.
--   4. Collapses internal whitespace runs to a single space.
--
-- Does NOT (yet):
--   - Reconcile alternate spellings ("St." vs "Saint", "N.Y." vs "New York")
--     — that's a Class-D synonym-rollup concern (docs/design/21_cleansing_layer_design.md §3)
--   - Case-fold
--
-- Scope: location_locality / location_region / location_metro / location_name
--        on integration.person; equivalent fields on integration.company;
--        ref.city.name_display / ref.state_province.name_display when
--        display-form generation is applied there. Deliberately NOT applied
--        to job_company_location_* — those are redundant with the current
--        experience row's company location.
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

create or replace function cleansing_rad.func_normalize_location(loc text)
  returns text
  language sql
  immutable
  strict
as $$
  select regexp_replace(
           trim(
             translate(
               normalize(loc, NFC),
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
  length(original)                                       as len_in,
  cleansing_rad.func_normalize_location(original)        as normalized,
  length(cleansing_rad.func_normalize_location(original)) as len_out
  from (values
    ('Zürich'::text),                               --already NFC — no length change
    (normalize('Zürich', NFD)),                     --NFD u + combining diaeresis → NFC ü (len shrinks)
    (normalize('São Paulo', NFD)),                  --NFD a + combining tilde → NFC ã
    ('Málaga'),                                     --already NFC
    ('  New   York  '),                             --whitespace collapse + trim
    ('O’ahu'),                                      --curly apostrophe → straight
    (null)                                          --NULL → NULL (STRICT)
  ) t(original);

