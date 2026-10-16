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


-- cleansing_rad.func_normalize_title(text) ---------------------------------------
--
-- Normalizes job-title strings for regex matching and JOIN comparison.
--   1. Lowercase.
--   2. Trim outer whitespace.
--   3. Collapse internal whitespace runs to a single space.
--
-- Deliberately minimal — job titles from PDL are already reasonably clean
-- (profiling a full delivery found no digits and no typographic quotes at
-- material volume). If future profiling surfaces punctuation-variant titles
-- ("Sr. Engineer" vs "Sr Engineer"), add a punctuation strip here.
--
-- Intended for: experience_duplicate.sql (cluster key on normalized title)
--          and any title-based filter / classifier — replaces the ad-hoc
--          lower(trim(e.title)) expressions those scripts inline today.
--
-- Deployment notes:
--   - IMMUTABLE  — safe in generated columns, expression indexes, and
--     regex-match WHERE clauses. Postgres will cache and inline.
--   - STRICT     — NULL input returns NULL immediately.
--   - Fast       — lower + trim + one regex. Materially the same cost as
--     inlined  lower(trim(...))  currently in the scripts.
--
-- Placement:
--   - For exploration: run this file before any script that calls it.
--   - Long-term: a Flyway repeatable migration (R__func_*.sql; see
--     docs/design/21_cleansing_layer_design.md §5). Same body.
-- ---------------------------------------------------------------------------

create or replace function cleansing_rad.func_normalize_title(title text)
  returns text
  language sql
  immutable
  strict
as $$
  select regexp_replace(
           trim(lower(title)),
           '\s+', ' ', 'g'
         );
$$;


-- CHECK: sample inputs → normalized outputs
select
  original,
  cleansing_rad.func_normalize_title(original) as normalized
  from (values
    ('Senior Engineer'::text),                      --title-case → lowercase
    ('  ENGINEER  '),                               --uppercase + leading/trailing whitespace
    ('Senior     Analyst'),                         --internal whitespace collapse
    ('Head of Product Marketing'),                  --multi-word
    (E'General\tManager'),                          --tab → single space
    (null)                                          --NULL → NULL (STRICT)
  ) t(original);

