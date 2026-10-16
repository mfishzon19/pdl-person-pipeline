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


---------------- Null-degrees rescue -----------------------------------------

-- Builds cleansing_rad.education_null_degree_rescue — a per-target-row
-- mapping that proposes a filled degree family for
-- integration.person_education rows whose `degrees` array is empty,
-- sourced from a sibling row at the same person + school with compatible
-- years.
--
-- Motivation (education_duplicate V-D):
--   After degree-family collapse + dropping majors from the cluster
--   key, the residual (pairs at same person+school+same non-null years
--   that STILL don't cluster) is dominated by `differ_because_one_null`:
--   one row has degrees=[] while its sibling has real degrees. Empty
--   degrees arrays are common across PDL person_education rows in
--   general (see pe_norm.sql V-A `with_degrees_rows`).
--
--   Clustering can't rescue these — the empty-degrees row's family_norm
--   is NULL, which is only equal-under-partition-by to other NULL
--   family_norm rows. But at ROW level, the empty row is often the same
--   education as a sibling: PDL emitted two records for one physical
--   education, one with degrees populated and one without.
--
--   This rescue proposes a filled degrees array (copied from the sibling
--   row) so a downstream re-cluster catches these.
--
--
-- CONFIDENCE TIERS
--
--   high    Target and source share BOTH start_year and end_year, both
--           non-null. Strongest match; the two rows are almost certainly
--           the same education.
--
--   medium  One year matches exactly (same start OR same end, both
--           non-null on the matching side), the other side has at least
--           one NULL. Weaker but still directional evidence.
--
--   low     Ranges overlap (some year window is shared) but no exact
--           year match. Weakest tier; most likely to produce false fills
--           for someone with a genuinely separate degree at the same
--           school.
--
-- Rows with NO year info on the target side are excluded — the rescue
-- can't tell whether they overlap with the source.
--
--
-- MULTIPLE SOURCE CANDIDATES
--
-- A target row can have multiple potential source rows at the same
-- person + school. The rescue picks ONE winner per target via
-- DISTINCT ON, ordered by:
--   1. confidence tier                  (high > medium > low)
--   2. source record_completeness_score (more evidence wins ties)
--   3. source id                        (deterministic tiebreak)
--
-- We store `filled_degrees_family_norm` (the source's precomputed family
-- string) rather than the raw filled_degrees jsonb — downstream cluster
-- comparison only needs the family form, and pe_norm already has it.
-- The raw source jsonbs (degrees/majors/minors) can be recovered via a
-- join to integration.person_education on source_education_id for
-- sampling.
--
--
-- DEPENDENCIES: cleansing_rad.pe_norm (fast projection of
--               integration.person_education with degrees_family_norm
--               precomputed — see pe_norm.sql). Rebuild pe_norm first
--               if either integration.person_education or
--               cleansing_rad.degree_family has changed.
--
-- V-checks: V-A rescue counts by confidence, V-B sample per tier, V-C
-- projected V-D collapse if the rescue is applied.


-- BUILD ----------------------------------------------------------------------

drop table if exists cleansing_rad.education_null_degree_rescue cascade;

create table cleansing_rad.education_null_degree_rescue as
with target as (
  --Rows with empty / NULL degrees. school_id must be non-null so we have
  --something to anchor the rescue to. start_year must be non-null so we
  --can evaluate year compatibility.
  select n.id            as target_id,
         n.person_id,
         n.school_id,
         n.start_year    as t_start,
         n.end_year      as t_end
    from cleansing_rad.pe_norm n
   where n.school_id  is not null
     and n.start_year is not null
     and not n.has_degrees
),
source as (
  --Rows with non-empty degrees. degrees_family_norm is already computed
  --in pe_norm; carry it through so V-C can COALESCE cheaply.
  select n.id                       as source_id,
         n.person_id,
         n.school_id,
         n.start_year               as s_start,
         n.end_year                 as s_end,
         n.degrees_family_norm      as s_family_norm,
         n.record_completeness_score as s_completeness
    from cleansing_rad.pe_norm n
   where n.school_id is not null
     and n.has_degrees
),
candidates as (
  select t.target_id,
         s.source_id,
         t.person_id,
         t.school_id,
         t.t_start, t.t_end,
         s.s_start, s.s_end,
         s.s_family_norm,
         s.s_completeness,
         case
           when t.t_start is not null and t.t_end is not null
                and s.s_start is not null and s.s_end is not null
                and s.s_start = t.t_start
                and s.s_end   = t.t_end
             then 'high'
           when (t.t_start is not null and s.s_start is not null and t.t_start = s.s_start
                 and (t.t_end is null or s.s_end is null))
             or (t.t_end   is not null and s.s_end   is not null and t.t_end   = s.s_end
                 and (t.t_start is null or s.s_start is null))
             then 'medium'
           when t.t_start is not null and t.t_end is not null
                and s.s_start is not null and s.s_end is not null
                and s.s_start <  t.t_end
                and t.t_start <  s.s_end
             then 'low'
           else null
         end                                                                       as confidence
    from target t
    join source s
      on s.person_id = t.person_id
     and s.school_id = t.school_id
),
winners as (
  select distinct on (target_id)
         target_id,
         source_id,
         person_id,
         school_id,
         t_start, t_end,
         s_start, s_end,
         s_family_norm,
         confidence
    from candidates
   where confidence is not null
   order by target_id,
            case confidence when 'high' then 3 when 'medium' then 2 when 'low' then 1 end desc,
            s_completeness                                                          desc,
            source_id
)
select target_id                                        as education_id,
       source_id                                        as source_education_id,
       person_id,
       school_id,
       t_start                                          as target_start_year,
       t_end                                            as target_end_year,
       s_start                                          as source_start_year,
       s_end                                            as source_end_year,
       s_family_norm                                    as filled_degrees_family_norm,
       confidence                                       as fill_confidence
  from winners;


-- INDEXES / STATS -----------------------------------------------------------

alter table cleansing_rad.education_null_degree_rescue
  add constraint education_null_degree_rescue_pkey primary key (education_id);

create index education_null_degree_rescue_confidence_idx
  on cleansing_rad.education_null_degree_rescue (fill_confidence);
create index education_null_degree_rescue_person_school_idx
  on cleansing_rad.education_null_degree_rescue (person_id, school_id);

analyze cleansing_rad.education_null_degree_rescue;


-- CHECKS --------------------------------------------------------------------

-- V-A. Rescue count by confidence tier + total unrescued null-degrees rows
--      still open. The key query — says how much of the null-degrees pool
--      the rescue can plausibly cover.
with total_null_degrees as (
  select count(*) as n
    from cleansing_rad.pe_norm n
   where n.school_id  is not null
     and n.start_year is not null
     and not n.has_degrees
)
select 'total null-degrees targets (school+start non-null)' as bucket,
       (select n from total_null_degrees)                    as count
union all
select 'rescued (all tiers)',
       (select count(*) from cleansing_rad.education_null_degree_rescue)
union all
select '  high confidence',
       (select count(*) from cleansing_rad.education_null_degree_rescue where fill_confidence = 'high')
union all
select '  medium confidence',
       (select count(*) from cleansing_rad.education_null_degree_rescue where fill_confidence = 'medium')
union all
select '  low confidence',
       (select count(*) from cleansing_rad.education_null_degree_rescue where fill_confidence = 'low')
union all
select 'unrescued (no compatible sibling found)',
       (select n from total_null_degrees) -
       (select count(*) from cleansing_rad.education_null_degree_rescue);


-- V-B. Sample 10 rescues per confidence tier — eyeball to confirm the
--      fill is sensible. Joins back to integration.person_education for
--      the target's original (empty) degrees and the source's degrees[],
--      majors[], minors[] jsonb bodies (not stored on the rescue table).
with sampled_ids as (
  select education_id, fill_confidence
    from (
      select education_id, fill_confidence,
             row_number() over (partition by fill_confidence order by random()) as rn
        from cleansing_rad.education_null_degree_rescue
    ) r
   where rn <= 10
)
select r.fill_confidence,
       r.education_id,
       t.person_id, t.school_id,
       r.target_start_year,
       r.target_end_year,
       t.degrees               as target_degrees_before,
       t.majors                as target_majors,
       r.source_education_id,
       r.source_start_year,
       r.source_end_year,
       s.degrees               as source_filled_degrees,
       s.majors                as source_majors,
       s.minors                as source_minors,
       r.filled_degrees_family_norm
  from cleansing_rad.education_null_degree_rescue r
  join sampled_ids si using (education_id)
  join integration.person_education t on t.id = r.education_id
  join integration.person_education s on s.id = r.source_education_id
 order by r.fill_confidence, r.education_id;


-- V-C. PROJECTED V-D COLLAPSE — rerun the V-D denominator with the
--      rescue applied virtually (LEFT JOIN rescue and COALESCE the
--      family_norm). Shows how much of V-D's residual the rescue would
--      eliminate.
--
--      Compare against the same columns of V-D in education_duplicate.sql
--      (cluster_match_pairs, differ_because_one_null,
--      differ_both_populated); the rescue should shrink the one-null
--      bucket and leave differ_both_populated unchanged.
with pe_effective as (
  select n.id,
         n.person_id,
         n.school_id,
         n.start_year,
         n.end_year,
         coalesce(n.degrees_family_norm, r.filled_degrees_family_norm) as degrees_family_norm
    from cleansing_rad.pe_norm n
    left join cleansing_rad.education_null_degree_rescue r on r.education_id = n.id
   where n.school_id  is not null
     and n.start_year is not null
     and n.end_year   is not null
)
select
  count(*)                                                          as total_same_ps_same_years_pairs,
  count(*) filter (
    where a.degrees_family_norm is not distinct from b.degrees_family_norm
  )                                                                 as cluster_match_pairs_post_rescue,
  count(*) filter (
    where a.degrees_family_norm is distinct from b.degrees_family_norm
  )                                                                 as differ_post_rescue,
  count(*) filter (
    where a.degrees_family_norm is distinct from b.degrees_family_norm
      and (a.degrees_family_norm is null or b.degrees_family_norm is null)
  )                                                                 as differ_because_one_still_null,
  count(*) filter (
    where a.degrees_family_norm is distinct from b.degrees_family_norm
      and a.degrees_family_norm is not null and b.degrees_family_norm is not null
  )                                                                 as differ_both_populated
from pe_effective a
join pe_effective b
  on b.person_id  = a.person_id
 and b.school_id  = a.school_id
 and b.start_year = a.start_year
 and b.end_year   = a.end_year
 and b.id         > a.id;
