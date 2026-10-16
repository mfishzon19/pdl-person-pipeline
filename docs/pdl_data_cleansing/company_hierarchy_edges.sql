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


---------------- Company hierarchy → long-form parent/child edges -----------

-- Builds cleansing_rad.company_hierarchy_edges — one row per direct
-- parent → child relationship in the normalized company hierarchy, with
-- matched PDL ids materialized on BOTH sides of every edge.
--
-- Long-form / edge-table shape (as opposed to the wide hierarchy table):
--
--   edge_id | parent_name               | parent_pdl_id | child_name                | child_pdl_id
--   --------+---------------------------+---------------+---------------------------+-------------
--   1       | Acme Holdings Inc         | aBc123…       | Acme Industrial Group Ltd | (null)
--   2       | Acme Industrial Group Ltd | (null)        | Globex Tooling LLC        | xYz789…
--   …
--
-- Derived from the normalized hierarchy: for each row whose deepest slot is
-- N (1..5), emit an edge (row's slot N-1, row's slot N). Because forward-
-- fill guarantees no depth gaps, second-deepest and deepest are always
-- adjacent depths.
--
-- Depth-0 (root-only) rows emit NO edges. A company listed as a parent with
-- no known children appears only in the match table
-- (cleansing_rad.company_hierarchy_pdl_match), not here. If downstream needs
-- "all companies in the hierarchy + PDL ids", read the match table directly.
--
-- Root columns (root_name / root_pdl_id / root_company_id): every edge
-- carries the top-of-branch company (== parent_current on the source
-- hierarchy row) so callers can filter to "all edges under company X"
-- without recursion. Root of a depth-1 edge equals the edge's parent; root
-- of a depth-5 edge is 4 levels above.
--
-- Relationship to sibling tables:
--   company_hierarchy             — input rows, names only, wide
--   company_hierarchy_pdl_match   — one row per distinct company name with
--                                   matched PDL id + tier
--   company_hierarchy_edges       — THIS TABLE. long-form edges, PDL ids on
--                                   both sides. Feeds the future
--                                   integration.company_affiliation wiring.
--
-- Refresh: stateless snapshot. DROP + CREATE AS SELECT.
--
-- DEPENDENCIES:
--   - cleansing_rad.company_hierarchy
--   - cleansing_rad.company_hierarchy_pdl_match


-- BUILD ----------------------------------------------------------------------

drop table if exists cleansing_rad.company_hierarchy_edges cascade;

--Common LEFT JOIN + column projection reused by all 5 depth-slice selects
--below. Materialize as a CTE so the same join tree isn't duplicated 5×.
create table cleansing_rad.company_hierarchy_edges as
with h as (
  select h.id                           as hierarchy_id,
         h.parent_current,
         h.child_1, h.child_2, h.child_3, h.child_4, h.child_5,
         mp.pdl_company_id as parent_current_pdl_id, mp.company_id as parent_current_company_id, mp.match_tier as parent_current_match_tier,
         m1.pdl_company_id as child_1_pdl_id,        m1.company_id as child_1_company_id,        m1.match_tier as child_1_match_tier,
         m2.pdl_company_id as child_2_pdl_id,        m2.company_id as child_2_company_id,        m2.match_tier as child_2_match_tier,
         m3.pdl_company_id as child_3_pdl_id,        m3.company_id as child_3_company_id,        m3.match_tier as child_3_match_tier,
         m4.pdl_company_id as child_4_pdl_id,        m4.company_id as child_4_company_id,        m4.match_tier as child_4_match_tier,
         m5.pdl_company_id as child_5_pdl_id,        m5.company_id as child_5_company_id,        m5.match_tier as child_5_match_tier
    from cleansing_rad.company_hierarchy h
    left join cleansing_rad.company_hierarchy_pdl_match mp on mp.source_name = h.parent_current
    left join cleansing_rad.company_hierarchy_pdl_match m1 on m1.source_name = h.child_1
    left join cleansing_rad.company_hierarchy_pdl_match m2 on m2.source_name = h.child_2
    left join cleansing_rad.company_hierarchy_pdl_match m3 on m3.source_name = h.child_3
    left join cleansing_rad.company_hierarchy_pdl_match m4 on m4.source_name = h.child_4
    left join cleansing_rad.company_hierarchy_pdl_match m5 on m5.source_name = h.child_5
)
--Depth 1 — parent_current → child_1 (row's deepest = child_1)
select hierarchy_id, 1::smallint as depth,
       parent_current   as parent_name, parent_current_pdl_id   as parent_pdl_id, parent_current_company_id   as parent_company_id, parent_current_match_tier   as parent_match_tier,
       child_1          as child_name,  child_1_pdl_id          as child_pdl_id,  child_1_company_id          as child_company_id,  child_1_match_tier          as child_match_tier,
       parent_current   as root_name,   parent_current_pdl_id   as root_pdl_id,   parent_current_company_id   as root_company_id
  from h
 where nullif(child_1, '') is not null
   and nullif(child_2, '') is null

union all
--Depth 2 — child_1 → child_2 (row's deepest = child_2)
select hierarchy_id, 2,
       child_1,   child_1_pdl_id,   child_1_company_id,   child_1_match_tier,
       child_2,   child_2_pdl_id,   child_2_company_id,   child_2_match_tier,
       parent_current, parent_current_pdl_id, parent_current_company_id
  from h
 where nullif(child_2, '') is not null
   and nullif(child_3, '') is null

union all
--Depth 3 — child_2 → child_3
select hierarchy_id, 3,
       child_2,   child_2_pdl_id,   child_2_company_id,   child_2_match_tier,
       child_3,   child_3_pdl_id,   child_3_company_id,   child_3_match_tier,
       parent_current, parent_current_pdl_id, parent_current_company_id
  from h
 where nullif(child_3, '') is not null
   and nullif(child_4, '') is null

union all
--Depth 4 — child_3 → child_4
select hierarchy_id, 4,
       child_3,   child_3_pdl_id,   child_3_company_id,   child_3_match_tier,
       child_4,   child_4_pdl_id,   child_4_company_id,   child_4_match_tier,
       parent_current, parent_current_pdl_id, parent_current_company_id
  from h
 where nullif(child_4, '') is not null
   and nullif(child_5, '') is null

union all
--Depth 5 — child_4 → child_5
select hierarchy_id, 5,
       child_4,   child_4_pdl_id,   child_4_company_id,   child_4_match_tier,
       child_5,   child_5_pdl_id,   child_5_company_id,   child_5_match_tier,
       parent_current, parent_current_pdl_id, parent_current_company_id
  from h
 where nullif(child_5, '') is not null;


-- INDEXES / STATS / CONSTRAINTS ---------------------------------------------

--Surrogate PK. `bigserial` on CREATE AS SELECT doesn't wire a sequence, so
--we add id + PK after the CREATE.
alter table cleansing_rad.company_hierarchy_edges
  add column edge_id bigserial primary key;

--Reverse-lookup indexes: "which edges mention company X?"
create index company_hierarchy_edges_parent_pdl_id_idx on cleansing_rad.company_hierarchy_edges (parent_pdl_id);
create index company_hierarchy_edges_child_pdl_id_idx  on cleansing_rad.company_hierarchy_edges (child_pdl_id);
create index company_hierarchy_edges_root_pdl_id_idx   on cleansing_rad.company_hierarchy_edges (root_pdl_id);
create index company_hierarchy_edges_hierarchy_id_idx  on cleansing_rad.company_hierarchy_edges (hierarchy_id);
create index company_hierarchy_edges_depth_idx         on cleansing_rad.company_hierarchy_edges (depth);

analyze cleansing_rad.company_hierarchy_edges;


-- CHECKS ---------------------------------------------------------------------

-- V1. Row count expected: sum of rows at depth 1..5 from the source
--     hierarchy (V2 in company_hierarchy_load.sql).
select count(*) as total_edges,
       count(distinct hierarchy_id) as source_rows_covered
  from cleansing_rad.company_hierarchy_edges;


-- V2. Edge distribution by depth
select depth, count(*) as edges
  from cleansing_rad.company_hierarchy_edges
 group by depth
 order by depth;


-- V3. PDL match rate on parent side and child side
select
  count(*)                                                 as total_edges,
  count(*) filter (where parent_pdl_id is not null)        as parent_matched,
  count(*) filter (where child_pdl_id  is not null)        as child_matched,
  count(*) filter (where parent_pdl_id is not null
                     and child_pdl_id  is not null)         as both_sides_matched,
  round(100.0 * count(*) filter (where parent_pdl_id is not null and child_pdl_id is not null)
             / nullif(count(*), 0), 1)                      as both_sides_pct
  from cleansing_rad.company_hierarchy_edges;


-- V4. One branch — all edges under a given root (replace the literal)
select edge_id, depth, parent_name, parent_pdl_id, child_name, child_pdl_id
  from cleansing_rad.company_hierarchy_edges
 where root_name = 'Acme Holdings Inc'
 order by depth, edge_id;


-- V5. Top 20 root companies by edge count (largest hierarchies)
select root_name,
       root_pdl_id,
       count(*) as edges_under_root
  from cleansing_rad.company_hierarchy_edges
 group by root_name, root_pdl_id
 order by edges_under_root desc
 limit 20;


-- V6. Sample edges where BOTH sides matched PDL (fully-resolved parent/child pairs)
select parent_name, parent_pdl_id, child_name, child_pdl_id, root_name
  from cleansing_rad.company_hierarchy_edges
 where parent_pdl_id is not null
   and child_pdl_id  is not null
 order by random()
 limit 15;
