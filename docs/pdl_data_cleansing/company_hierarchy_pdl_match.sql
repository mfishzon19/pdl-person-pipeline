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


---------------- Match hierarchy companies to PDL company ids ----------------

-- Builds:
--   1. cleansing_rad.company_brand_lookup         — precomputed brand for every
--                                                    integration.company row,
--                                                    indexed on brand + trigram-
--                                                    on-name. Enables a fast
--                                                    exact-brand JOIN.
--   2. cleansing_rad.company_hierarchy_pdl_match  — one row per distinct company
--                                                    name in the hierarchy (across
--                                                    all 6 slot columns) with its
--                                                    matched pdl_company_id + tier.
--   3. cleansing_rad.company_hierarchy_with_pdl_ids — VIEW: joins the match table
--                                                    6× to company_hierarchy so
--                                                    every row shows the full
--                                                    parent-chain names + their
--                                                    PDL ids in one row.
--
-- Two-tier match:
--   Tier 1 (exact_brand)      — func_company_brand(source)
--                                = func_company_brand(pdl)
--   Tier 2 (substring_brand)  — lower(pdl.name) LIKE '%source_brand%',
--                                length(source_brand) >= 4
--                                (only for tier-1 misses)
--   Otherwise                  — no_match
--   (Tier 3 — cleaner_api — is applied afterwards by
--    scripts/company_hierarchy_pdl_cleaner.py.)
--
-- Tiebreak (when a source_name maps to multiple candidates):
--   1. Prefer the candidate with the most person-experience rows pointing at
--      it (the canonical entity usually carries the most employees; regional
--      or duplicate entities carry fewer)
--   2. Prefer shortest integration.company.name (the canonical brand is
--      usually the cleanest; regional variants have geographic suffixes)
--   3. Alphabetical pdl_company_id — deterministic fallback
--
-- Keyed on source_name (not (hierarchy_id, slot)) because the same company
-- name appears in many hierarchy rows (a large parent can head hundreds of
-- rows). Deduping to one match per unique name avoids redundant lookups and
-- lets re-match be a cheap TRUNCATE + rerun.
--
-- DEPENDENCIES:
--   - cleansing_rad.func_company_brand()    (func_company_brand.sql)
--   - cleansing_rad.company_hierarchy       (company_hierarchy_load.sql)
--
--
-- ============================================================================
-- IMPLEMENTATION STEP — what happens after all match tiers have run
-- ============================================================================
--
-- After exact_brand + substring_brand + cleaner_api have all been applied,
-- rows still marked 'no_match' are companies PDL does not hold at all —
-- typically defunct historical companies, very small entities, or names too
-- corrupted / non-Latin for the Cleaner to resolve.
--
-- These residual companies are still real corporate entities that appear as
-- ancestors in the hierarchy — leaving them out breaks the hierarchy graph.
-- Implementation must:
--
-- 1. CREATE COMPANY ROWS for every 'no_match' company.
--    Each becomes a new row in integration.company with pdl_company_id = NULL
--    (a departure from the current invariant that every integration.company
--    row has a PDL id — decide during implementation whether to (a) make
--    pdl_company_id nullable, or (b) extend the integration.company source
--    enum with a new 'company_hierarchy' value that marks PDL-absent rows;
--    see docs/data_model/08_company.md). Populate name from source_name;
--    other scalars stay null.
--
-- 2. WIRE COMPANY_AFFILIATION edges from the hierarchy.
--    integration.company_affiliation gains an edge for every parent → child
--    relationship in the normalized hierarchy (company_hierarchy_edges.sql
--    materializes exactly these):
--        subject_company_id    — the shallower company (parent side)
--        affiliated_company_id — the deeper company (child side)
--        relationship_id       — FK to ref.pdl_relationship. Acquisitions /
--                                historical predecessors map to
--                                'direct_subsidiary'; if a distinct
--                                'historical_predecessor' semantic is
--                                desired, add it to ref.pdl_relationship
--                                (loader-discovered pattern, ADR-0011).
--        dataset_version       — 'company_hierarchy_<snapshot_date>'
--
-- 3. ORDER: create integration.company rows FIRST (both for cleaner_api
--    hits that landed a pdl_id we don't hold locally, AND for no_match
--    companies). THEN wire affiliation edges — otherwise the FK to
--    integration.company won't resolve.
--
-- 4. IDEMPOTENCY: the created rows need a natural key (normalized brand +
--    company name?) so a re-run detects existing rows instead of
--    duplicating every historical company.
-- ============================================================================


-- PREREQ — precomputed brand per integration.company row --------------------

create extension if not exists pg_trgm;

drop table if exists cleansing_rad.company_brand_lookup cascade;

--UNLOGGED — this is a derived cache, rebuildable at will. WAL cost avoided.
--experience_count drives tiebreak #1.
create unlogged table cleansing_rad.company_brand_lookup as
select c.id                                       as company_id,
       c.pdl_company_id,
       c.name,
       c.industry_id,
       cleansing_rad.func_company_brand(c.name)   as brand,
       coalesce(e.experience_count, 0)            as experience_count
  from integration.company c
  left join (
    select company_id, count(*) as experience_count
      from integration.experience
     where company_id is not null
     group by company_id
  ) e on e.company_id = c.id
 where nullif(c.name, '') is not null;

--Index on brand for the tier-1 exact-brand JOIN. This is the whole point of
--precomputing — without it, tier 1 would seq-scan integration.company per lookup.
create index company_brand_lookup_brand_idx     on cleansing_rad.company_brand_lookup (brand);
create index company_brand_lookup_pdl_id_idx    on cleansing_rad.company_brand_lookup (pdl_company_id);
create index company_brand_lookup_name_trgm_idx on cleansing_rad.company_brand_lookup using gin (lower(name) gin_trgm_ops);

analyze cleansing_rad.company_brand_lookup;


-- BUILD — match table --------------------------------------------------------

drop table if exists cleansing_rad.company_hierarchy_pdl_match cascade;

create table cleansing_rad.company_hierarchy_pdl_match (
  source_name         text primary key,
  source_brand        text        not null,
  pdl_company_id      text,
  company_id          bigint,
  matched_name        text,
  match_tier          text        not null default 'no_match',
  --Cleaner API audit — populated by scripts/company_hierarchy_pdl_cleaner.py
  --for rows that stayed 'no_match' after the two-tier SQL match. Rows with
  --match_tier='cleaner_api' have these fields set; SQL-tier matches leave
  --them null.
  pdl_lookup_status   smallint,
  pdl_lookup_response jsonb,
  pdl_lookup_at       timestamptz
);

--Seed with every distinct company name from any slot in the hierarchy. Skip
--names whose brand-normalized form is too short to be a discriminating
--substring (guards against "co", "as" collapsing everything).
insert into cleansing_rad.company_hierarchy_pdl_match (source_name, source_brand)
select distinct name,
       cleansing_rad.func_company_brand(name) as brand
  from (
    select parent_current as name from cleansing_rad.company_hierarchy where nullif(parent_current, '') is not null
    union
    select child_1                from cleansing_rad.company_hierarchy where nullif(child_1,        '') is not null
    union
    select child_2                from cleansing_rad.company_hierarchy where nullif(child_2,        '') is not null
    union
    select child_3                from cleansing_rad.company_hierarchy where nullif(child_3,        '') is not null
    union
    select child_4                from cleansing_rad.company_hierarchy where nullif(child_4,        '') is not null
    union
    select child_5                from cleansing_rad.company_hierarchy where nullif(child_5,        '') is not null
  ) s
 where length(cleansing_rad.func_company_brand(name)) >= 3;


-- TIER 1 — exact brand match --------------------------------------------------

with candidates as (
  select m.source_name,
         c.pdl_company_id,
         c.company_id,
         c.name                as matched_name,
         c.experience_count,
         length(c.name)        as name_length
    from cleansing_rad.company_hierarchy_pdl_match m
    join cleansing_rad.company_brand_lookup c on c.brand = m.source_brand
   where m.match_tier = 'no_match'
     and length(c.brand) >= 3
),
picked as (
  select distinct on (source_name)
         source_name, pdl_company_id, company_id, matched_name
    from candidates
   order by source_name,
            experience_count desc,
            name_length      asc,
            pdl_company_id   asc
)
update cleansing_rad.company_hierarchy_pdl_match m
   set pdl_company_id = p.pdl_company_id,
       company_id     = p.company_id,
       matched_name   = p.matched_name,
       match_tier     = 'exact_brand'
  from picked p
 where m.source_name = p.source_name;


-- TIER 2 — substring brand match (tier-1 misses only) ------------------------

with candidates as (
  select m.source_name,
         c.pdl_company_id,
         c.company_id,
         c.name                as matched_name,
         c.experience_count,
         length(c.name)        as name_length
    from cleansing_rad.company_hierarchy_pdl_match m
    join cleansing_rad.company_brand_lookup c
      on lower(c.name) like '%' || m.source_brand || '%'
   where m.match_tier = 'no_match'
     and length(m.source_brand) >= 4    -- stricter than tier 1
),
picked as (
  select distinct on (source_name)
         source_name, pdl_company_id, company_id, matched_name
    from candidates
   order by source_name,
            experience_count desc,
            name_length      asc,
            pdl_company_id   asc
)
update cleansing_rad.company_hierarchy_pdl_match m
   set pdl_company_id = p.pdl_company_id,
       company_id     = p.company_id,
       matched_name   = p.matched_name,
       match_tier     = 'substring_brand'
  from picked p
 where m.source_name = p.source_name;


-- INDEXES / STATS ------------------------------------------------------------

create index company_hierarchy_pdl_match_pdl_id_idx on cleansing_rad.company_hierarchy_pdl_match (pdl_company_id);
create index company_hierarchy_pdl_match_tier_idx   on cleansing_rad.company_hierarchy_pdl_match (match_tier);

analyze cleansing_rad.company_hierarchy_pdl_match;


-- VIEW — wide form: hierarchy row + PDL ids for each slot --------------------

create or replace view cleansing_rad.company_hierarchy_with_pdl_ids as
select h.id,
       h.date_col,
       h.parent_current, mp.pdl_company_id as parent_current_pdl_id, mp.match_tier as parent_current_match_tier,
       h.child_1,        m1.pdl_company_id as child_1_pdl_id,        m1.match_tier as child_1_match_tier,
       h.child_2,        m2.pdl_company_id as child_2_pdl_id,        m2.match_tier as child_2_match_tier,
       h.child_3,        m3.pdl_company_id as child_3_pdl_id,        m3.match_tier as child_3_match_tier,
       h.child_4,        m4.pdl_company_id as child_4_pdl_id,        m4.match_tier as child_4_match_tier,
       h.child_5,        m5.pdl_company_id as child_5_pdl_id,        m5.match_tier as child_5_match_tier,
       h.notes
  from cleansing_rad.company_hierarchy h
  left join cleansing_rad.company_hierarchy_pdl_match mp on mp.source_name = h.parent_current
  left join cleansing_rad.company_hierarchy_pdl_match m1 on m1.source_name = h.child_1
  left join cleansing_rad.company_hierarchy_pdl_match m2 on m2.source_name = h.child_2
  left join cleansing_rad.company_hierarchy_pdl_match m3 on m3.source_name = h.child_3
  left join cleansing_rad.company_hierarchy_pdl_match m4 on m4.source_name = h.child_4
  left join cleansing_rad.company_hierarchy_pdl_match m5 on m5.source_name = h.child_5;


-- CHECKS ---------------------------------------------------------------------

-- V1. Overall match rate by tier
select match_tier, count(*) as distinct_companies
  from cleansing_rad.company_hierarchy_pdl_match
 group by match_tier
 order by distinct_companies desc;


-- V2. One ancestor chain — proves the view stitches PDL ids into the
--     hierarchy correctly. Replace the literal with a depth-2 company.
select id, parent_current, parent_current_pdl_id, parent_current_match_tier,
           child_1,        child_1_pdl_id,        child_1_match_tier,
           child_2,        child_2_pdl_id,        child_2_match_tier
  from cleansing_rad.company_hierarchy_with_pdl_ids
 where child_2 = 'Globex Tooling LLC';


-- V3. Match coverage per slot column (distinct source_names per slot)
with slots as (
  select 'parent_current' as slot, parent_current as name from cleansing_rad.company_hierarchy where parent_current is not null
  union select 'child_1', child_1 from cleansing_rad.company_hierarchy where child_1 is not null
  union select 'child_2', child_2 from cleansing_rad.company_hierarchy where child_2 is not null
  union select 'child_3', child_3 from cleansing_rad.company_hierarchy where child_3 is not null
  union select 'child_4', child_4 from cleansing_rad.company_hierarchy where child_4 is not null
  union select 'child_5', child_5 from cleansing_rad.company_hierarchy where child_5 is not null
)
select s.slot,
       count(distinct s.name)                                                                                as distinct_names,
       count(distinct s.name) filter (where m.match_tier = 'exact_brand')                                    as exact_hits,
       count(distinct s.name) filter (where m.match_tier = 'substring_brand')                                as substring_hits,
       count(distinct s.name) filter (where m.match_tier = 'no_match' or m.match_tier is null)               as no_match,
       round(
         100.0 * count(distinct s.name) filter (where m.pdl_company_id is not null)
         / nullif(count(distinct s.name), 0),
         1
       )                                                                                                     as match_rate_pct
  from slots s
  left join cleansing_rad.company_hierarchy_pdl_match m on m.source_name = s.name
 group by s.slot
 order by s.slot;


-- V4. First 20 unmatched companies — for triage / manual review
select source_name, source_brand
  from cleansing_rad.company_hierarchy_pdl_match
 where match_tier = 'no_match'
 order by source_name
 limit 20;


-- V5. Ambiguity check — tier-1 names that had 2+ candidate PDL ids (the
--     tiebreak decided these; spot-check that it picked the canonical one)
select m.source_name, m.matched_name, m.pdl_company_id,
       count(c.pdl_company_id) as candidate_count
  from cleansing_rad.company_hierarchy_pdl_match m
  join cleansing_rad.company_brand_lookup c on c.brand = m.source_brand
 where m.match_tier = 'exact_brand'
 group by m.source_name, m.matched_name, m.pdl_company_id
having count(c.pdl_company_id) > 1
 order by candidate_count desc
 limit 20;
