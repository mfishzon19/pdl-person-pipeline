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


---------------- Apply the broken-PDL-company predicate ---------------------

-- The "apply" side of func_is_broken_pdl_company (see
-- func_is_broken_pdl_company.sql for the predicate + partial index +
-- sanity checks).
--
-- Two SELECTs to preview delete impact + two DELETE templates behind them:
--   V5. SELECT + DELETE — the broken-canonical rows in integration.company
--   V6. SELECT + DELETE — the experience rows attributed to them
--
-- Uses an inline "known-good exception" list to preserve real companies whose
-- brand name happens to be a role/occupation token. Extend the list as
-- review surfaces more real companies.


-- Known exceptions — real companies flagged as broken -----------------------
--
-- A small handful of pdl_company_ids trip func_is_broken_pdl_company because
-- their brand name happens to be an occupation / role token — but the row is
-- actually a real company. Excluded from V5/V6 delete queries by
-- pdl_company_id. Add here when review surfaces more.
--
-- One entry today: a real company whose brand name is the occupation token
-- 'coach' (kept after review). The id is listed in the NOT IN clauses below.


-- V5. SELECT companies to DELETE — the broken canonicals, minus known
--     exceptions.
select c.id                                                                    as company_id,
       c.pdl_company_id,
       c.name,
       c.website,
       c.size,
       c.source,
       (select count(*) from integration.experience e where e.company_id = c.id) as exp_rows
  from integration.company c
 where cleansing_rad.func_is_broken_pdl_company(c.name)
   and c.pdl_company_id not in (
     'example-pdl-company-id'   -- allow-list: ids reviewed as genuine companies (e.g. one literally named 'coach')
   )
 order by exp_rows desc;

-- To DELETE (uncomment when ready — irreversible until the next full
-- pipeline rebuild, which repopulates integration.company from source.
-- Run V6's delete FIRST if the FK on integration.experience.company_id
-- is ON DELETE RESTRICT):
-- delete from integration.company
--  where cleansing_rad.func_is_broken_pdl_company(name)
--    and pdl_company_id not in (
--      'example-pdl-company-id'   -- allow-list: ids reviewed as genuine companies (e.g. one literally named 'coach')
--    );


-- V6. SELECT experience rows to DELETE — attributed to the broken canonicals,
--     minus known exceptions.
--
--     PERF NOTE — array-aggregated ANY form. Runs in tens of milliseconds
--     against a full-delivery experience table. Other shapes we tried were dramatically worse:
--       - Straight JOIN … WHERE func(…):        tens of seconds
--       - CTE + JOIN:                           several seconds
--       - IN (subquery):                        several seconds (Postgres
--                                                     compiles it to a hash
--                                                     semi-join, same plan as
--                                                     CTE + JOIN)
--       - ARRAY(subquery) + = ANY:              milliseconds  ← this one
--     Why ARRAY-ANY wins: the InitPlan collapses the broken ids into an
--     ARRAY once, and `company_id = ANY(array)` gets rewritten to a bitmap OR
--     of a few hundred index probes on idx_experience_company_id. The other
--     shapes make the planner think it needs a hash join over the full
--     experience table (because it misestimates the predicate's selectivity —
--     the partial index doesn't fix that; the predicate is opaque to
--     statistics).
select e.person_id,
       e.company_id,
       e.title,
       e.start_year,
       e.end_year
  from integration.experience e
 where e.company_id = any (
   array(
     select id from integration.company
      where cleansing_rad.func_is_broken_pdl_company(name)
        and pdl_company_id not in (
          'example-pdl-company-id'   -- allow-list: ids reviewed as genuine companies (e.g. one literally named 'coach')
        )
   )
 )
 order by e.person_id, e.company_id;

-- To DELETE (uncomment when ready — irreversible until the next full
-- pipeline rebuild, which repopulates integration.experience from source).
-- Same ARRAY-ANY shape so the planner picks the bitmap-index plan:
-- delete from integration.experience e
--  where e.company_id = any (
--    array(
--      select id from integration.company
--       where cleansing_rad.func_is_broken_pdl_company(name)
--         and pdl_company_id not in (
--           'example-pdl-company-id'   -- allow-list: ids reviewed as genuine companies (e.g. one literally named 'coach')
--         )
--    )
--  );
