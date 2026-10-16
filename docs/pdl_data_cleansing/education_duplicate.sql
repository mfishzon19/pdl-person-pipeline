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


---------------- Education-row duplicate classification ---------------------

-- Builds cleansing_rad.education_duplicate — every row of every same
-- person + same school + same degrees-family cluster of ≥2 rows,
-- annotated with a cluster-level status describing the RELATIONSHIP
-- SHAPE among the cluster's rows.
--
-- Mirror of cleansing_rad.experience_duplicate. Read that file first for
-- the design; only the parts that differ for education are re-documented
-- here.
--
-- Cluster key: (person_id, school_id, degrees_family_norm) where
-- degrees_family_norm is the '|'-joined sorted set of degree FAMILIES
-- (via cleansing_rad.degree_family) — 'bachelors', 'masters',
-- 'doctorates', 'associates', or 'other' — for the row's degrees[]
-- array. NULL / empty array → NULL norm. Postgres treats NULL = NULL
-- in PARTITION BY, so null-school clusters with null-school (same
-- person + same family), null-degrees clusters with null-degrees, etc.
--
-- NOTES ON THE KEY DESIGN (see also README "Open questions"):
--
--   * Years are NOT in the cluster key. Rows with different but related
--     year ranges (near-duplicates: 2010-2014 vs 2011-2014) end up in
--     the same cluster and get labeled by year-relationship (Superset,
--     Overlap, Disjoined). Same shape as experience_duplicate.
--
--   * Majors are NOT in the cluster key. The V-D residual on a baseline
--     run (majors still in the key) showed that the large majority of
--     majors-differ pairs at same person+school+years are one array
--     being a subset of the other — PDL emits varying MAJORS SPECIFICITY
--     for the same education (["business"] vs ["business","management"]).
--     Dropping majors from the key merges these correctly. The trade-off
--     is a very small number of pairs with legitimately disjoint majors
--     that get false-merged; accepted.
--
--   * Degrees are collapsed to FAMILY via cleansing_rad.degree_family.
--     PDL emits varying DEGREE SPECIFICITY (["masters"] vs ["master of
--     laws","masters"]) — family collapse fixes it. See degree_family.sql
--     for the map (self-populating; every canonical form maps to one of
--     four families, or 'other').


-- dup_cluster_status --------------------------------------------------------
--
-- Cluster-level classification. Every row in a cluster shares the same
-- status string. Describes the RELATIONSHIP shape present among the
-- cluster's rows plus flags for null key columns.
--
-- BASE LABELS
--
--   Null School      Every row has school_id IS NULL.
--   Null Degrees     Every row has degrees_family_norm IS NULL
--                    (degrees array empty or all canonical forms
--                    unmapped in degree_family).
--
--   Exact Duplicate  ≥1 pair has identical (start_year, end_year), both non-null.
--   Superset/Subset  ≥1 pair has strict year containment (one range fully contains the other).
--   Overlap Tenure   ≥1 pair has partial year overlap, OR ≥1 side has NULL year.
--   Disjoined Tenure ≥1 pair has non-overlapping years (gap or boundary-touching sequential).
--
-- COMPOUND STATUS
--
-- Fixed order (null-key flags first, then relationships most-specific
-- to least-specific):
--
--   Null School + Null Degrees + Exact Duplicate + Superset/Subset
--     + Overlap Tenure + Disjoined Tenure


-- Other output columns ------------------------------------------------------
--
--   record_completeness_score  (0-8)
--     Per-row evidence score. Not used in dup_cluster_status; it is the
--     primary ranking signal in education_is_keep.sql.
--     Scoring:
--       +1 degrees array is non-null AND non-empty
--       +1 majors  array is non-null AND non-empty
--       +1 minors  array is non-null AND non-empty
--       +1 start_year populated
--       +1 end_year   populated
--       +1 gpa populated
--       +1 summary populated
--       +1 length(summary) >= 50
--
--   cluster_size
--     Number of rows in the (person_id, school_id, degrees_family_norm)
--     cluster. Always ≥ 2 for rows in this table.
--
--   is_keep  (bool, NULL)
--     Built as NULL here; education_is_keep.sql then marks one winner per
--     cluster. Merging the losers' fields into the winner (e.g. a UNION
--     of majors[]) is still an open design question.


-- DEPENDENCIES: integration.person_education, cleansing_rad.degree_family,
--               cleansing_rad.pe_norm (perf sidecar; build pe_norm.sql
--               first so V-D/V-E/V-G run in seconds instead of minutes).
--
-- V-checks below (V-A .. V-H; V-F sits at the end of the file) are
-- VERIFICATION queries — read-only
-- spot-checks confirming the build did what we think it did + surfacing
-- the taxonomy distribution + per-row shape evidence. V-D is kept as a
-- quality signal (pairs at same person+school+same non-null years that
-- STILL don't cluster). V-G and V-H are per-row PDL-shape profiling
-- (multi-degree-family records and multi-majors records) that explain
-- the design choices — read them alongside V-D to understand the
-- residual.


-- BUILD ----------------------------------------------------------------------

drop table if exists cleansing_rad.education_duplicate cascade;

create table cleansing_rad.education_duplicate as
with scored as (
  --Every row in integration.person_education with completeness score and
  --the degrees_family_norm cluster key. Null-family rows (empty degrees
  --or all degrees unmapped in degree_family) are INCLUDED — they cluster
  --with other null-family rows for the same person + school and pick up
  --the "Null Degrees" compound flag.
  select pe.id                                                                          as education_id,
         pe.person_id,
         pe.school_id,
         pe.degrees,
         pe.majors,
         pe.minors,
         pe.gpa,
         pe.summary,
         pe.start_year,
         pe.end_year,
         (select string_agg(distinct df.family, '|' order by df.family)
            from jsonb_array_elements_text(pe.degrees) x
            join cleansing_rad.degree_family df on df.canonical_form = lower(trim(x))
         )                                                                              as degrees_family_norm,
         (case when pe.degrees is not null and jsonb_typeof(pe.degrees) = 'array'
                and jsonb_array_length(pe.degrees) > 0 then 1 else 0 end
        + case when pe.majors  is not null and jsonb_typeof(pe.majors)  = 'array'
                and jsonb_array_length(pe.majors)  > 0 then 1 else 0 end
        + case when pe.minors  is not null and jsonb_typeof(pe.minors)  = 'array'
                and jsonb_array_length(pe.minors)  > 0 then 1 else 0 end
        + case when pe.start_year is not null           then 1 else 0 end
        + case when pe.end_year   is not null           then 1 else 0 end
        + case when pe.gpa        is not null           then 1 else 0 end
        + case when pe.summary    is not null           then 1 else 0 end
        + case when length(pe.summary) >= 50            then 1 else 0 end
         )                                                                              as record_completeness_score
    from integration.person_education pe
),
clustered as (
  select s.*,
         count(*) over w                          as cluster_size,
         bool_and(s.school_id           is null) over w as cluster_school_all_null,
         bool_and(s.degrees_family_norm is null) over w as cluster_degrees_all_null
    from scored s
   window w as (partition by s.person_id, s.school_id, s.degrees_family_norm)
),
in_clusters as (
  select * from clustered where cluster_size > 1
),
pair_flags as (
  --For each row, aggregate pair-level relationship flags against every
  --other row in its cluster (self-join, b.education_id <> a.education_id).
  select
    a.education_id,
    a.person_id,
    a.school_id,
    a.degrees,
    a.majors,
    a.minors,
    a.gpa,
    a.summary,
    a.start_year,
    a.end_year,
    a.degrees_family_norm,
    a.record_completeness_score,
    a.cluster_size,
    a.cluster_school_all_null,
    a.cluster_degrees_all_null,
    bool_or(
      a.start_year is not null and a.end_year is not null
      and b.start_year is not null and b.end_year is not null
      and a.start_year = b.start_year and a.end_year = b.end_year
    )                                                                                   as has_exact_duplicate,
    bool_or(
      a.start_year is not null and a.end_year is not null
      and b.start_year is not null and b.end_year is not null
      and (a.start_year <> b.start_year or a.end_year <> b.end_year)  -- not identical
      and (
        (a.start_year <= b.start_year and a.end_year >= b.end_year)  -- a contains b
        or
        (b.start_year <= a.start_year and b.end_year >= a.end_year)  -- b contains a
      )
    )                                                                                   as has_superset_subset,
    bool_or(
      (a.start_year is not null and a.end_year is not null
       and b.start_year is not null and b.end_year is not null
       and a.start_year < b.end_year and b.start_year < a.end_year   -- ranges overlap
       and not (a.start_year <= b.start_year and a.end_year >= b.end_year)
       and not (b.start_year <= a.start_year and b.end_year >= a.end_year))
      or
      (a.start_year is null or a.end_year is null
       or b.start_year is null or b.end_year is null)
    )                                                                                   as has_overlap_tenure,
    bool_or(
      a.start_year is not null and a.end_year is not null
      and b.start_year is not null and b.end_year is not null
      and (a.end_year <= b.start_year or b.end_year <= a.start_year)
    )                                                                                   as has_disjoined_tenure
  from in_clusters a
  join in_clusters b
    on b.person_id           =  a.person_id
   and b.school_id           is not distinct from a.school_id
   and b.degrees_family_norm is not distinct from a.degrees_family_norm
   and b.education_id        <> a.education_id
  group by
    a.education_id, a.person_id, a.school_id, a.degrees, a.majors, a.minors,
    a.gpa, a.summary, a.start_year, a.end_year, a.degrees_family_norm,
    a.record_completeness_score, a.cluster_size,
    a.cluster_school_all_null, a.cluster_degrees_all_null
)
select education_id,
       person_id,
       school_id,
       degrees,
       majors,
       minors,
       gpa,
       summary,
       start_year,
       end_year,
       degrees_family_norm,
       record_completeness_score,
       cluster_size,
       nullif(
         concat_ws(
           ' + ',
           case when cluster_school_all_null  then 'Null School'      end,
           case when cluster_degrees_all_null then 'Null Degrees'     end,
           case when has_exact_duplicate      then 'Exact Duplicate'  end,
           case when has_superset_subset      then 'Superset/Subset'  end,
           case when has_overlap_tenure       then 'Overlap Tenure'   end,
           case when has_disjoined_tenure     then 'Disjoined Tenure' end
         ), ''
       )                                                                                as dup_cluster_status,
       null::bool                                                                       as is_keep
  from pair_flags;


-- INDEXES / STATS -----------------------------------------------------------

alter table cleansing_rad.education_duplicate
  add constraint education_duplicate_pkey primary key (education_id);

create index education_duplicate_person_school_idx on cleansing_rad.education_duplicate (person_id, school_id);
create index education_duplicate_cluster_size_idx  on cleansing_rad.education_duplicate (cluster_size);
create index education_duplicate_status_idx        on cleansing_rad.education_duplicate (dup_cluster_status);
create index education_duplicate_is_keep_idx       on cleansing_rad.education_duplicate (is_keep);

analyze cleansing_rad.education_duplicate;


-- CHECKS --------------------------------------------------------------------

-- V-A. Cluster count per dup_cluster_status — top-line taxonomy.
select dup_cluster_status,
       count(distinct (person_id, school_id, degrees_family_norm))         as clusters,
       count(*)                                                             as rows
  from cleansing_rad.education_duplicate
 group by dup_cluster_status
 order by clusters desc;


-- V-B. Sample cluster per status — one example of each status, all rows.
with one_per_status as (
  select distinct on (dup_cluster_status)
         dup_cluster_status, person_id, school_id, degrees_family_norm
    from cleansing_rad.education_duplicate
   order by dup_cluster_status, random()
)
select d.dup_cluster_status,
       d.person_id, d.school_id, d.education_id,
       d.degrees, d.majors, d.minors, d.gpa,
       d.start_year, d.end_year,
       d.record_completeness_score, d.cluster_size
  from cleansing_rad.education_duplicate d
  join one_per_status s
    on s.person_id           =  d.person_id
   and s.school_id           is not distinct from d.school_id
   and s.degrees_family_norm is not distinct from d.degrees_family_norm
 order by d.dup_cluster_status, d.person_id, d.school_id, d.record_completeness_score desc;


-- V-C. DUMP FOR A SPECIFIC STATUS (all populations). Change the
--      `dup_cluster_status = '…'` value to the bucket you want to review.
--      Population filtering (if any) happens downstream; keeping this
--      all-populations makes the sample easier to browse.
--
--      Run V-A first to list the status combinations present in your
--      data. Any non-empty combination of the six base labels can occur
--      (always in the fixed order above), for example:
--
--        Disjoined Tenure
--        Exact Duplicate
--        Null Degrees + Overlap Tenure
--        Null School + Null Degrees + Superset/Subset + Disjoined Tenure
select dup_cluster_status,
       person_id,
       school_id,
       education_id,
       degrees,
       majors,
       minors,
       gpa,
       start_year,
       end_year,
       degrees_family_norm,
       record_completeness_score,
       cluster_size
  from cleansing_rad.education_duplicate
 where dup_cluster_status  = 'Superset/Subset'          -- CHANGE ME
 order by person_id,
          school_id nulls first,
          degrees_family_norm,
          record_completeness_score desc,
          education_id;


-- V-D. QUALITY CHECK — pairs at same (person_id, school_id) with
--      IDENTICAL non-null (start_year, end_year) that STILL don't
--      cluster together (differ in degrees_family_norm).
--
--      With the family collapse + majors dropped, this should be small.
--      Anything that remains is either:
--        (a) legit — different degree families at same school + years
--            (e.g., BA in economics 2010-2014 + BS in engineering 2010-2014 —
--             double major at graduation)
--        (b) PDL data noise where one row's degrees are missing (empty
--            array → NULL family) and the other row has a real family.
--
--      What a full delivery showed:
--
--        Baseline (raw jsonb norms, majors in cluster key): only a
--        minority of same person + school + years pairs matched bit-exact;
--        most were "rescued by canonicalization" — the arrays differed in
--        degrees only, majors only, or both.
--
--        Post-rebuild (family collapse, majors dropped from key): the
--        cluster-match share of those pairs rose severalfold; the residual
--        that still differs in degrees_family_norm splits into two kinds:
--          - the larger part is one side having degrees=[] → NULL family
--            (a PDL data gap, not fixable via better clustering; see
--            education_null_degree_rescue.sql).
--          - the rest is legit-looking cases: bundled multi-family records
--            (e.g., ["bachelors","masters"] in one row) vs single-family
--            records at same person + school + years. See V-G evidence.
select
  count(*)                                                          as total_same_ps_same_years_pairs,
  count(*) filter (
    where a.degrees_family_norm is not distinct from b.degrees_family_norm
  )                                                                 as cluster_match_pairs,
  count(*) filter (
    where a.degrees_family_norm is distinct from b.degrees_family_norm
  )                                                                 as differ_in_degrees_family,
  count(*) filter (
    where a.degrees_family_norm is distinct from b.degrees_family_norm
      and (a.degrees_family_norm is null or b.degrees_family_norm is null)
  )                                                                 as differ_because_one_null,
  count(*) filter (
    where a.degrees_family_norm is distinct from b.degrees_family_norm
      and a.degrees_family_norm is not null and b.degrees_family_norm is not null
  )                                                                 as differ_both_populated
from cleansing_rad.pe_norm a
join cleansing_rad.pe_norm b
  on b.person_id  = a.person_id
 and b.school_id  = a.school_id
 and b.start_year = a.start_year
 and b.end_year   = a.end_year
 and b.id         > a.id
where a.school_id  is not null
  and a.start_year is not null
  and a.end_year   is not null;


-- V-E. SAMPLE — 30 random pairs from V-D's "differ_in_degrees_family"
--      pool. Eyeball to confirm whether the residual is legit
--      distinct-degree-families or PDL noise.
with sampled_pairs as (
  select a.id                  as a_id,
         b.id                  as b_id,
         a.person_id,
         a.school_id,
         a.start_year,
         a.end_year,
         a.degrees_family_norm as a_family,
         b.degrees_family_norm as b_family
    from cleansing_rad.pe_norm a
    join cleansing_rad.pe_norm b
      on b.person_id  = a.person_id
     and b.school_id  = a.school_id
     and b.start_year = a.start_year
     and b.end_year   = a.end_year
     and b.id         > a.id
   where a.school_id  is not null
     and a.start_year is not null
     and a.end_year   is not null
     and a.degrees_family_norm is distinct from b.degrees_family_norm
   order by random()
   limit 30
)
select s.person_id, s.school_id, s.start_year, s.end_year,
       s.a_id, pa.degrees as a_degrees, s.a_family, pa.majors as a_majors,
       s.b_id, pb.degrees as b_degrees, s.b_family, pb.majors as b_majors
  from sampled_pairs s
  join integration.person_education pa on pa.id = s.a_id
  join integration.person_education pb on pb.id = s.b_id
 order by s.person_id, s.school_id;


-- V-G. MULTI-DEGREE-FAMILY RECORDS — per-row evidence that PDL emits
--      SINGLE education records containing 2+ distinct degree families
--      (e.g., ["bachelor of law","bachelors","master of laws","masters"]
--      in one row → bachelors + masters). Motivates degrees_family_norm
--      being a joined SET of families rather than a single family, and
--      explains part of V-D's `differ_both_populated` residual: a
--      bundled multi-family row at the same person+school+years as a
--      single-family row won't cluster together (family sets differ).

-- V-G.1 — row count by distinct-family fanout per row
select degrees_family_count as distinct_family_count_per_row,
       count(*)             as rows
  from cleansing_rad.pe_norm
 where has_degrees
 group by degrees_family_count
 order by degrees_family_count;

-- V-G.2 — sample 30 rows with 2+ distinct degree families
with sampled as (
  select id, degrees_family_norm
    from cleansing_rad.pe_norm
   where degrees_family_count >= 2
   order by random()
   limit 30
)
select pe.person_id, pe.school_id, pe.start_year, pe.end_year,
       pe.degrees, pe.majors,
       s.degrees_family_norm
  from sampled s
  join integration.person_education pe on pe.id = s.id
 order by pe.person_id;


-- V-H. MULTI-MAJORS RECORDS — per-row evidence that PDL emits single
--      records with 2+ majors in the array. Motivates the subset/
--      superset pattern (V-D sample analysis showed most majors-differ
--      pairs at same person+school+years are one array being a subset
--      of the other) and dropping majors from the cluster key.

-- V-H.1 — row count by majors array length
select jsonb_array_length(pe.majors) as majors_count,
       count(*) as rows
  from integration.person_education pe
 where pe.majors is not null
   and jsonb_typeof(pe.majors) = 'array'
 group by jsonb_array_length(pe.majors)
 order by majors_count;

-- V-H.2 — sample 30 rows with 2+ majors
select pe.person_id, pe.school_id, pe.start_year, pe.end_year,
       pe.degrees, pe.majors, pe.minors
  from integration.person_education pe
 where pe.majors is not null
   and jsonb_typeof(pe.majors) = 'array'
   and jsonb_array_length(pe.majors) >= 2
 order by random()
 limit 30;


-- V-F. MULTI-MAJORS SAME-CLUSTER — descriptive statistic: within a
--      given cluster (same person, school, degrees_family), how many
--      distinct majors sets show up? With majors NO LONGER in the
--      cluster key, this measures how much majors variation each
--      cluster absorbs. High counts here are expected and OK — the
--      cluster represents the same education, and majors will be
--      union-merged at is_keep time.
select distinct_majors_norm_count,
       count(*) as clusters,
       sum(row_count) as rows
  from (
    select person_id, school_id, degrees_family_norm,
           count(distinct coalesce(
             (select string_agg(lower(trim(x)), '|' order by lower(trim(x)))
                from jsonb_array_elements_text(majors) x),
             '<null>'
           )) as distinct_majors_norm_count,
           count(*) as row_count
      from cleansing_rad.education_duplicate
     group by person_id, school_id, degrees_family_norm
  ) g
 group by distinct_majors_norm_count
 order by distinct_majors_norm_count desc;
