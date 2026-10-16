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


-- cleansing_rad.func_normalize_prose(text) ----------------------------------
--
-- Normalizes long-form free-text prose fields (headline, summary, and any
-- future *_summary companions on experience / education / company).
--   1. NFC-folds decomposed Unicode into precomposed form.
--   2. Replaces typographic punctuation with ASCII equivalents
--      (curly apostrophes/quotes → straight, en/em/horizontal dashes → hyphen,
--       standalone acute/grave → straight apostrophe).
--   3. Trims outer whitespace.
--   4. Collapses runs of spaces/tabs to a single space but PRESERVES newlines
--      (\n) so paragraph structure survives — important when downstream ever
--      renders the field for humans.
--
-- Prose fields are the biggest source of typographic characters in PDL data:
-- curly apostrophes are common in populated 'summary' values. Normalizing here
-- is what makes dedup / JOIN / FTS work sanely.
--
-- Used by: (planned) headline + summary cleansing on integration.person.
--          Will extend to experience.summary, person_education.summary,
--          integration.company.summary / .headline when those are added.
--
-- Deployment notes:
--   - IMMUTABLE  — safe in generated columns and expression indexes.
--   - STRICT     — NULL input returns NULL.
--   - Cost       — regex + translate on longer strings than names. Still
--                  fast enough for row-at-a-time evaluation; summaries are
--                  short paragraphs, so per-call time is trivial.
--
-- Placement:
--   - For exploration: run this file before any script that calls it.
--   - Long-term: a Flyway repeatable migration (R__func_*.sql; see
--     docs/design/21_cleansing_layer_design.md §5). Same body.
-- ---------------------------------------------------------------------------

create or replace function cleansing_rad.func_normalize_prose(t text)
  returns text
  language sql
  immutable
  strict
as $$
  select regexp_replace(
           trim(
             translate(
               normalize(t, NFC),
               --typographic → ASCII (position-aligned single-char pairs)
               U&'\2018\2019\201A\201B\201C\201D\2013\2014\2015\00B4\0060',
                 '''''''''""---'''
             )
           ),
           '[^\S\n]+', ' ', 'g'    --collapse runs of non-newline whitespace
         );
$$;


-- CHECK: sample inputs → normalized outputs
select
  original,
  cleansing_rad.func_normalize_prose(original) as normalized
  from (values
    ('He said “hello”'::text),                     --curly double quotes → straight
    ('it’s complicated'),                          --curly apostrophe → straight
    ('Example University — Class of 2015'),        --em-dash → hyphen
    ('en–dash and em—dash'),                       --en-dash + em-dash → hyphen
    (E'line 1\n\n  line 2\n\tline 3'),             --paragraph structure preserved; tabs/spaces collapsed
    ('  trimmed   spaces  '),                      --leading/trailing/collapsed spaces
    (null)                                         --NULL → NULL (STRICT)
  ) t(original);

