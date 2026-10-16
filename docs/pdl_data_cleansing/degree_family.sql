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


---------------- Degree family map -----------------------------------------

-- Builds cleansing_rad.degree_family — one row per distinct
-- lowercased-trimmed degree string observed in
-- integration.person_education.degrees[], mapped to a coarse family
-- ('bachelors' / 'masters' / 'doctorates' / 'associates' / 'other').
--
-- Motivation (from the education_duplicate V-D residual):
--   PDL emits degrees as a CONTROLLED VOCABULARY — a small, fixed set of
--   distinct strings. But PDL emits the SAME education
--   at inconsistent granularities:
--
--     row 1: degrees = ["masters"]                        -- generic family
--     row 2: degrees = ["master of laws", "masters"]      -- family + specific
--
--   Sorted-set bit-exact hashing (education_duplicate cluster key)
--   treats these as DIFFERENT clusters, so they don't dedup. V-D at
--   same-person + same-school + same-years showed most such pairs were
--   "rescued by canonicalization" — i.e. bit-exact missed them because
--   the raw arrays are different sets of the same-family degrees.
--
--   Collapsing every canonical_form to its family fixes it. Two rows
--   that PDL emits as `["masters"]` and `["master of laws", "masters"]`
--   both normalize to family-set {"masters"} — same cluster.
--
--
-- HOW THE MAP IS BUILT
--
-- Self-populating via a prefix rule against the live degrees in
-- integration.person_education. Any string that doesn't match the
-- prefix rule lands as family='other' and surfaces in V-B for manual
-- review. This means: adding new PDL degree strings later auto-populates
-- (with correct family for anything the rule catches).
--
-- The rule (see BUILD below):
--   bachelor*  | bachelors           → bachelors
--   master*    | masters             → masters
--   magister*  | magisters           → masters   -- Latin form; magister juris = master of laws
--   doctor*    | doctorates          → doctorates
--   associate* | associates          → associates
--   anything else                    → other
--
-- Corner cases the rule handles cleanly:
--   - Plural forms of the family word itself (bachelors/masters/doctorates/associates) →
--     mapped to their own family
--   - Compound names like "bachelor of arts in business administration",
--     "master of science in nursing", "doctor of philosophy" → matched
--     by prefix
--
-- Manual overrides: UPDATE cleansing_rad.degree_family SET family = '…'
-- WHERE canonical_form = '…' after the seed runs. Rebuilding drops and
-- re-seeds; overrides need to be re-applied. Once the map stabilizes,
-- freeze it into a hand-written INSERT.


-- BUILD ----------------------------------------------------------------------

drop table if exists cleansing_rad.degree_family cascade;

create table cleansing_rad.degree_family (
  canonical_form  text primary key,
  family          text not null,
  notes           text
);

insert into cleansing_rad.degree_family (canonical_form, family)
select v as canonical_form,
       case
         when v like 'bachelor%'  then 'bachelors'
         when v = 'bachelors'     then 'bachelors'
         when v like 'master%'    then 'masters'
         when v = 'masters'       then 'masters'
         when v like 'magister%'  then 'masters'
         when v = 'magisters'     then 'masters'
         when v like 'doctor%'    then 'doctorates'
         when v = 'doctorates'    then 'doctorates'
         when v like 'associate%' then 'associates'
         when v = 'associates'    then 'associates'
         else 'other'
       end as family
  from (
    select distinct lower(trim(x)) as v
      from integration.person_education pe,
           lateral jsonb_array_elements_text(pe.degrees) x
     where pe.degrees is not null
  ) src;

create index degree_family_family_idx on cleansing_rad.degree_family (family);

analyze cleansing_rad.degree_family;


-- CHECKS --------------------------------------------------------------------

-- V-A. Family coverage summary — how many canonical forms per family +
--      how many source rows those forms account for (weight-check).
select df.family,
       count(distinct df.canonical_form)  as canonical_forms,
       sum(occ.n)                          as source_occurrences
  from cleansing_rad.degree_family df
  join (
    select lower(trim(x)) as v, count(*) as n
      from integration.person_education pe,
           lateral jsonb_array_elements_text(pe.degrees) x
     where pe.degrees is not null
     group by lower(trim(x))
  ) occ on occ.v = df.canonical_form
 group by df.family
 order by source_occurrences desc;


-- V-B. Manual-review pool — anything that landed in family='other'.
--      Expect this to be empty (or very short) for PDL's current
--      controlled vocab. If it's populated, extend the prefix rule or
--      add manual overrides.
select df.canonical_form,
       occ.n as source_occurrences
  from cleansing_rad.degree_family df
  join (
    select lower(trim(x)) as v, count(*) as n
      from integration.person_education pe,
           lateral jsonb_array_elements_text(pe.degrees) x
     where pe.degrees is not null
     group by lower(trim(x))
  ) occ on occ.v = df.canonical_form
 where df.family = 'other'
 order by occ.n desc, df.canonical_form;


-- V-C. Full table dump — every canonical_form → family assignment.
--      Sort by family + occurrence for reviewability.
select df.family,
       df.canonical_form,
       occ.n as source_occurrences
  from cleansing_rad.degree_family df
  join (
    select lower(trim(x)) as v, count(*) as n
      from integration.person_education pe,
           lateral jsonb_array_elements_text(pe.degrees) x
     where pe.degrees is not null
     group by lower(trim(x))
  ) occ on occ.v = df.canonical_form
 order by df.family, occ.n desc, df.canonical_form;


-- USAGE ---------------------------------------------------------------------
--
-- education_duplicate.sql and pe_norm.sql collapse a person_education row's
-- degrees[] array to a normalized family-set string (the cluster key
-- degrees_family_norm) with:
--
--     (select string_agg(distinct df.family, '|' order by df.family)
--        from jsonb_array_elements_text(pe.degrees) x
--        join cleansing_rad.degree_family df
--          on df.canonical_form = lower(trim(x))) as degrees_family_norm
--
-- This replaces an earlier exact-set key over the raw degree strings.
-- Majors are handled by leaving them out of the cluster key; a parallel
-- major_family map is not planned unless the V-D residual calls for it.
