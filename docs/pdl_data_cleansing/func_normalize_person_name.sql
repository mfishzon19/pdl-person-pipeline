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


-- cleansing_rad.func_normalize_person_name(text) ---------------------------------
--
-- Normalizes person-name fields (first / last / full).
--   1. NFC-folds decomposed Unicode into precomposed form.
--      e.g., 'i' + combining dot above (U+0307)  →  'İ' (U+0130 precomposed)
--   2. Replaces typographic punctuation with ASCII equivalents.
--      e.g., O'Reilly (U+2019 curly)  →  O'Reilly (U+0027 straight)
--   3. Strips CREDENTIAL SUFFIXES at end of string (case-insensitive):
--      esq, esquire, jd, llb, llm, md, phd, dds, dvm, cfa, cpa, pe, rn, do,
--      dc, dpt, pharmd, mba. Optional preceding comma; optional trailing dot.
--      e.g., 'John Smith, Esq.'  →  'John Smith'
--      e.g., 'Jane Doe MD'       →  'Jane Doe'
--   4. Strips HONORIFIC PREFIXES at start of string (case-insensitive):
--      mr, mrs, ms, miss, mx, dr/doctor, prof/professor, rev/reverend,
--      fr/father, sister, sir, dame, lord, lady, hon/honorable, capt/captain,
--      col/colonel, gen/general, lt/lieutenant, maj/major, sgt/sergeant.
--      Requires whitespace or comma after the prefix — 'Drew' won't match 'dr'.
--      e.g., 'Dr. Robert Jones'    →  'Robert Jones'
--      e.g., 'Prof. Alice Chen'    →  'Alice Chen'
--      e.g., 'Ms. Emily J, PhD'    →  'Emily J' (both prefix + suffix stripped)
--   5. Trims outer whitespace and collapses internal runs to a single space.
--
-- Preserved (NOT stripped):
--   - Generational suffixes: Jr., Sr., II, III, IV, V — these carry identity
--     for family disambiguation and are considered part of the name.
--     Enable stripping by adding `jr|sr|ii|iii|iv|v` to the credential-suffix
--     regex if that changes.
--
-- Used by: invalid_names_filter.sql (name-validation and _valid_name /
--          _invalid_name table population). Also useful anywhere else that
--          compares or de-duplicates by name (JOIN keys, name-based dedup).
--
-- Deployment notes:
--   - IMMUTABLE  — safe in generated columns, expression indexes, and CTE
--     WHERE clauses. Postgres will cache and inline.
--   - STRICT     — NULL input returns NULL immediately without invoking body.
--   - Fast       — 3 regex passes + translate on short strings. No material
--                  runtime hit.
--
-- Placement:
--   - For exploration: run this file before any script that calls it.
--   - Long-term: a Flyway repeatable migration (R__func_*.sql; see
--     docs/design/21_cleansing_layer_design.md §5). Same body.
-- ---------------------------------------------------------------------------

create or replace function cleansing_rad.func_normalize_person_name(name text)
  returns text
  language sql
  immutable
  strict
as $$
  --Steps applied inside-out:
  --  1. NFC normalize (decomposed → precomposed)
  --  2. Typographic → ASCII (curly quotes / dashes → straight)
  --  3. Strip credential suffix (case-insensitive, end of string)
  --  4. Strip honorific prefix (case-insensitive, start of string)
  --  5. Trim outer whitespace
  --  6. Collapse internal whitespace runs
  select regexp_replace(
           trim(
             regexp_replace(
               regexp_replace(
                 translate(
                   normalize(name, NFC),
                   --typographic → ASCII (position-aligned single-char pairs)
                   U&'\2018\2019\201A\201B\201C\201D\2013\2014\2015\00B4\0060',
                     '''''''''""---'''
                 ),
                 --credential suffix — requires whitespace/comma BEFORE the token
                 --so 'Filipe' (ends in 'pe') doesn't get stripped
                 '[\s,]+(esq|esquire|jd|llb|llm|md|phd|dds|dvm|cfa|cpa|pe|rn|do|dc|dpt|pharmd|mba)\.?\s*$',
                 '',
                 'i'
               ),
               --honorific prefix — requires whitespace/comma AFTER the token
               --so 'Drew' (starts with 'dr') doesn't get stripped
               '^(mr|mrs|ms|miss|mx|dr|doctor|prof|professor|rev|reverend|fr|father|sister|sir|dame|lord|lady|hon|honorable|capt|captain|col|colonel|gen|general|lt|lieutenant|maj|major|sgt|sergeant)\.?[\s,]+',
               '',
               'i'
             )
           ),
           '\s+', ' ', 'g'
         );
$$;


-- CHECK: sample inputs → normalized outputs
select
  original,
  length(original)                                            as len_in,
  cleansing_rad.func_normalize_person_name(original)          as normalized,
  length(cleansing_rad.func_normalize_person_name(original))  as len_out
  from (values
    --unicode + typography
    ('O’Reilly'::text),                             --curly apostrophe → straight
    ('O`Reilly'),                                   --grave → apostrophe
    (normalize('İrem', NFD)),                       --NFD i + combining dot → NFC İ
    ('  John   Doe  '),                             --leading/trailing/collapsed whitespace
    ('Café'),                                       --already NFC — no change
    (normalize('Café', NFD)),                       --NFD é (e + combining acute) → NFC

    --credential suffixes
    ('John Smith Esq'),                             --unpunctuated suffix
    ('John Smith, Esq'),                            --comma-separated suffix
    ('John Smith, Esq.'),                           --with trailing dot
    ('Jane Doe MD'),                                --medical
    ('Alice Chen PhD'),                             --academic
    ('Robert Jones, JD'),                           --professional degree
    ('Emily Park, LLM'),                            --postgraduate degree
    ('Ms. Emily Johnson, PhD'),                     --prefix + suffix combined

    --honorific prefixes
    ('Dr. Robert Jones'),                           --medical prefix
    ('Prof. Alice Chen'),                           --academic prefix
    ('Rev. Mark Lee'),                              --religious prefix
    ('Capt. Sam Rivera'),                           --military prefix
    ('Mr. John Smith'),                             --Mr.
    ('Mrs. Jane Doe'),                              --Mrs.
    ('Honorable Jane Q Public'),                    --Honorable (full word)

    --preserved (generational suffixes, false-positive guards)
    ('John Smith Jr.'),                             --preserved
    ('Robert Jones III'),                           --preserved
    ('William Carter IV'),                          --preserved
    ('Filipe'),                                     --ends in 'pe' but no space — NOT stripped
    ('Drew'),                                       --starts with 'dr' but no space — NOT stripped
    ('Rebecca'),                                    --starts with 're' but 'reverend' needs word break

    (null)                                          --NULL → NULL (STRICT)
  ) t(original);
