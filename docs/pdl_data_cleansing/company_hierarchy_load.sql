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


---------------- Company hierarchy — load + normalize ------------------------

-- Builds cleansing_rad.company_hierarchy — a NORMALIZED load of a
-- user-supplied company hierarchy spreadsheet (parent companies, their
-- subsidiaries, acquired companies, predecessors, regional offices).
--
-- Input format (CSV, UTF-8, header row):
--
--   date_col, parent_current, child_1, child_2, child_3, child_4, child_5, notes
--
-- The spreadsheet encodes hierarchy positionally (implicit inheritance): a
-- row places a company in exactly ONE of parent_current / child_1..5, and
-- its ancestor chain is inferred from the nearest preceding rows at
-- shallower depths. That shape is fragile — it breaks the moment you
-- filter, sort, or randomly access rows.
--
-- This loader forward-fills the ancestor chain during load. After
-- normalization, every row carries its FULL path from root to itself:
--
--   raw source                     normalized
--   ---------------------------    ---------------------------
--   parent = Acme Holdings Inc     parent = Acme Holdings Inc
--   (child_1..5 empty)             (child_1..5 empty)
--
--   child_1 = Acme Industrial      parent  = Acme Holdings Inc
--   Group Ltd                      child_1 = Acme Industrial Group Ltd
--                                  (child_2..5 empty)
--
--   child_2 = Globex Tooling LLC   parent  = Acme Holdings Inc
--                                  child_1 = Acme Industrial Group Ltd
--                                  child_2 = Globex Tooling LLC
--
-- Algorithm: walk rows in id order, maintaining state[parent, c1..c5]. When
-- a row's source has a value at depth N: update state[N], reset state[>N]
-- (a new branch started at depth N invalidates deeper state from the
-- previous branch). Emit the full state to each output row.
--
-- Pre-normalization fixup: rows where parent_current is set AND child_5 is
-- set AND child_1..4 are all empty are an authoring accident — a comment
-- typed into the child_5 cell (e.g. "relationship ended in 2022"). Move
-- the child_5 string to `notes` before the forward-fill walk — otherwise
-- it would leak into subsequent rows as an ancestor.
--
-- Load rules:
--   1. First-8-columns-only (trailing empties dropped)
--   2. Every cell trim(both whitespace)
--   3. Fully-blank rows dropped (apply when preparing the CSV)
--   4. Anomaly fixup: parent+child_5-only rows → move child_5 to notes
--   5. Forward-fill ancestor chain per row (see algorithm above)
--
-- Source: docs/pdl_data_cleansing/data/company_hierarchy.csv
--         (not committed — supply your own; see data/README.md. A tiny
--          synthetic example lives at data/company_hierarchy.example.csv.)


-- BUILD ----------------------------------------------------------------------

create schema if not exists cleansing_rad;

drop table if exists cleansing_rad.company_hierarchy cascade;

create table cleansing_rad.company_hierarchy (
  id             bigserial primary key,
  date_col       text,
  parent_current text,
  child_1        text,
  child_2        text,
  child_3        text,
  child_4        text,
  child_5        text,
  notes          text
);

--Client-side \copy — server can't reach the local file. Path is relative to
--the shell CWD at invocation time. When running via `psql -f`, invoke from
--the repo root so the relative path below resolves. Point it at
--data/company_hierarchy.example.csv to try the routine on synthetic data.
\copy cleansing_rad.company_hierarchy (date_col, parent_current, child_1, child_2, child_3, child_4, child_5, notes) from 'docs/pdl_data_cleansing/data/company_hierarchy.csv' with (format csv, header true)


-- FIXUP — parent+child_5-only rows are comments typed into child_5 ----------
--
-- A legit hierarchy can't jump from depth 0 (parent) straight to depth 5
-- (child_5) — depths 1-4 would have to be populated too. So a row with
-- parent set + child_5 set + child_1..4 all empty is a spreadsheet-authoring
-- accident. Move it to notes BEFORE the forward-fill walk, otherwise the
-- comment string leaks into subsequent rows as an ancestor.
update cleansing_rad.company_hierarchy
   set notes   = trim(both ' ' from concat_ws(' | ', nullif(notes, ''), child_5)),
       child_5 = null
 where nullif(parent_current, '') is not null
   and nullif(child_1,        '') is null
   and nullif(child_2,        '') is null
   and nullif(child_3,        '') is null
   and nullif(child_4,        '') is null
   and nullif(child_5,        '') is not null;


-- NORMALIZE — forward-fill ancestor chain per row -----------------------------
--
-- PL/pgSQL cursor walk in id order. State variables carry the "current"
-- value at each depth. When source row has a value at depth N: replace
-- state[N] and NULL state[>N] (a new branch at depth N invalidates any
-- deeper ancestor from the previous branch). Emit the full state to each
-- output row via UPDATE.
do $$
declare
  st_parent text;
  st_c1     text;
  st_c2     text;
  st_c3     text;
  st_c4     text;
  st_c5     text;
  r         record;
begin
  for r in
    select id, parent_current, child_1, child_2, child_3, child_4, child_5
      from cleansing_rad.company_hierarchy
     order by id
  loop
    if nullif(r.parent_current, '') is not null then
      st_parent := r.parent_current;
      st_c1 := null; st_c2 := null; st_c3 := null; st_c4 := null; st_c5 := null;
    end if;
    if nullif(r.child_1, '') is not null then
      st_c1 := r.child_1;
      st_c2 := null; st_c3 := null; st_c4 := null; st_c5 := null;
    end if;
    if nullif(r.child_2, '') is not null then
      st_c2 := r.child_2;
      st_c3 := null; st_c4 := null; st_c5 := null;
    end if;
    if nullif(r.child_3, '') is not null then
      st_c3 := r.child_3;
      st_c4 := null; st_c5 := null;
    end if;
    if nullif(r.child_4, '') is not null then
      st_c4 := r.child_4;
      st_c5 := null;
    end if;
    if nullif(r.child_5, '') is not null then
      st_c5 := r.child_5;
    end if;

    update cleansing_rad.company_hierarchy
       set parent_current = st_parent,
           child_1        = st_c1,
           child_2        = st_c2,
           child_3        = st_c3,
           child_4        = st_c4,
           child_5        = st_c5
     where id = r.id;
  end loop;
end $$;


-- INDEXES / STATS ------------------------------------------------------------

--Trigram GIN on each company-name column for fuzzy lookups. Small table —
--index cost is trivial.
create extension if not exists pg_trgm;

create index company_hierarchy_parent_trgm_idx  on cleansing_rad.company_hierarchy using gin (lower(parent_current) gin_trgm_ops);
create index company_hierarchy_child_1_trgm_idx on cleansing_rad.company_hierarchy using gin (lower(child_1) gin_trgm_ops);
create index company_hierarchy_child_2_trgm_idx on cleansing_rad.company_hierarchy using gin (lower(child_2) gin_trgm_ops);
create index company_hierarchy_child_3_trgm_idx on cleansing_rad.company_hierarchy using gin (lower(child_3) gin_trgm_ops);
create index company_hierarchy_child_4_trgm_idx on cleansing_rad.company_hierarchy using gin (lower(child_4) gin_trgm_ops);
create index company_hierarchy_child_5_trgm_idx on cleansing_rad.company_hierarchy using gin (lower(child_5) gin_trgm_ops);

analyze cleansing_rad.company_hierarchy;


-- CHECKS ---------------------------------------------------------------------

-- V1. After normalization: parent_current populated on EVERY row.
--     Deeper columns populated only on rows at that depth or deeper.
select count(*)                                                        as total_rows,
       count(*) filter (where nullif(date_col,      '') is not null)   as populated_date,
       count(*) filter (where nullif(parent_current,'') is not null)   as populated_parent,
       count(*) filter (where nullif(child_1,       '') is not null)   as populated_child_1,
       count(*) filter (where nullif(child_2,       '') is not null)   as populated_child_2,
       count(*) filter (where nullif(child_3,       '') is not null)   as populated_child_3,
       count(*) filter (where nullif(child_4,       '') is not null)   as populated_child_4,
       count(*) filter (where nullif(child_5,       '') is not null)   as populated_child_5,
       count(*) filter (where nullif(notes,         '') is not null)   as populated_notes
  from cleansing_rad.company_hierarchy;


-- V2. Rows by deepest depth — post-normalization, every row has a well-
--     defined depth = index of the deepest populated column.
select case
         when nullif(child_5,       '') is not null then 5
         when nullif(child_4,       '') is not null then 4
         when nullif(child_3,       '') is not null then 3
         when nullif(child_2,       '') is not null then 2
         when nullif(child_1,       '') is not null then 1
         when nullif(parent_current,'') is not null then 0
         else -1
       end                                       as depth,
       count(*)                                  as rows
  from cleansing_rad.company_hierarchy
 group by 1
 order by depth;


-- V3. One branch end-to-end — a depth-2 row should show its FULL chain.
--     Replace the literal with a depth-2 company from your input.
select id, parent_current, child_1, child_2, child_3, child_4, child_5
  from cleansing_rad.company_hierarchy
 where child_2 = 'Globex Tooling LLC';


-- V4. Top 20 parents by descendant count.
select parent_current,
       count(*)                                                   as descendants
  from cleansing_rad.company_hierarchy
 group by parent_current
 order by descendants desc
 limit 20;


-- V5. Sanity: any row where parent_current is NULL is a normalization bug
--     (should be 0)
select count(*) as unrooted_rows
  from cleansing_rad.company_hierarchy
 where parent_current is null;


-- V6. Sanity: any row where a deeper column is populated but a shallower
--     one is NULL is a normalization bug (should be 0)
select count(*) as gap_in_chain_rows
  from cleansing_rad.company_hierarchy
 where (child_1 is null and (child_2 is not null or child_3 is not null or child_4 is not null or child_5 is not null))
    or (child_2 is null and (child_3 is not null or child_4 is not null or child_5 is not null))
    or (child_3 is null and (child_4 is not null or child_5 is not null))
    or (child_4 is null and (child_5 is not null));
