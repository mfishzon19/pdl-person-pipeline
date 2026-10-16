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


---------------- Education is_keep — canonical row per cluster --------------

-- Populates cleansing_rad.education_duplicate.is_keep — for each
-- (person_id, school_id, degrees_family_norm) cluster of ≥2 rows,
-- marks ONE row as the canonical winner (is_keep=true) and the rest
-- as losers (is_keep=false). Rows NOT in a cluster (cluster_size = 1)
-- don't appear in cleansing_rad.education_duplicate at all — they are
-- implicitly kept in downstream _staged.
--
-- This is an UPDATE against the existing education_duplicate table, not
-- a rebuild. Rules will iterate; the UPDATE takes seconds on a full delivery.
--
--
-- RANKING RULE
--
-- Within each cluster, order rows by (all DESC unless noted):
--
--   1. record_completeness_score
--        Primary signal. Fields covered: has_degrees, has_majors,
--        has_minors, start_year populated, end_year populated, gpa
--        populated, summary populated, length(summary) >= 50.
--
--   2. tenure_width  (end_year - start_year, coalesced to 0)
--        Prefer the row that names a wider tenure — more informative,
--        and often the "master record" that got merged from partial
--        sub-tenures.
--
--   3. majors_array_length
--        Richer majors set wins — supersets are more informative than
--        subsets (see education_duplicate V-D findings: PDL emits
--        varying majors specificity, and most of the majors-differ pool
--        was subset/superset).
--
--   4. degrees_array_length
--        Richer degrees array wins. A row emitting ["bachelor of law",
--        "bachelors"] beats one emitting just ["bachelors"] as the
--        canonical record.
--
--   5. minors_array_length
--        Same principle for minors.
--
--   6. length(summary)  (NULLS LAST)
--        Longer summary wins on a tie of everything above.
--
--   7. education_id  (ASC)
--        Deterministic tiebreak so is_keep is stable across rebuilds.
--
-- Exactly one row per cluster gets is_keep=true. Ties are broken by
-- rule 7 deterministically.
--
--
-- CANONICAL FIELD MERGE (deferred)
--
-- is_keep marks the ROW, not the field values. Downstream collapse
-- to _staged will still need to decide what to do with the losers'
-- non-null fields (majors[] union? degrees[] union? summary
-- concatenation?). That's a separate design pass.
--
--
-- RESCUE INTEGRATION (deferred)
--
-- cleansing_rad.education_null_degree_rescue is NOT applied here.
-- Rescued rows (mostly low-confidence, per rescue V-A) currently
-- sit in their own (Null Degrees + …) clusters. Integrating the rescue
-- means rebuilding education_duplicate with a COALESCE cluster key
-- (pe_norm.degrees_family_norm, rescue.filled_degrees_family_norm) —
-- covered in a follow-up. is_keep will need to re-run after that.
--
--
-- DEPENDENCIES: cleansing_rad.education_duplicate (built).
--
-- V-checks: V-A kept vs loser counts; V-B sample cluster showing the
-- winner + losers; V-C dump of a specific status showing is_keep.


-- APPLY ----------------------------------------------------------------------

update cleansing_rad.education_duplicate d
   set is_keep = r.is_keep
  from (
    select education_id,
           (row_number() over (
              partition by person_id, school_id, degrees_family_norm
              order by
                record_completeness_score                                              desc,
                coalesce(end_year - start_year, 0)                                     desc,
                coalesce(case when jsonb_typeof(majors)  = 'array'
                              then jsonb_array_length(majors)  end, 0)                 desc,
                coalesce(case when jsonb_typeof(degrees) = 'array'
                              then jsonb_array_length(degrees) end, 0)                 desc,
                coalesce(case when jsonb_typeof(minors)  = 'array'
                              then jsonb_array_length(minors)  end, 0)                 desc,
                length(summary)                                                        desc nulls last,
                education_id                                                           asc
           ) = 1)                                                                      as is_keep
      from cleansing_rad.education_duplicate
  ) r
 where d.education_id = r.education_id;

analyze cleansing_rad.education_duplicate;


-- CHECKS --------------------------------------------------------------------

-- V-A. Kept vs loser counts + cluster count.
select is_keep,
       count(*)                                                     as rows,
       count(distinct (person_id, school_id, degrees_family_norm))  as clusters
  from cleansing_rad.education_duplicate
 group by is_keep
 order by is_keep desc nulls first;


-- V-B. Sample 10 random clusters showing winner + losers side by side.
--      Sanity check that the ranking is picking the "richest" row.
with sample_clusters as (
  select distinct on (person_id, school_id, degrees_family_norm)
         person_id, school_id, degrees_family_norm
    from cleansing_rad.education_duplicate
   order by person_id, school_id, degrees_family_norm, random()
   limit 10
)
select d.is_keep,
       d.person_id, d.school_id, d.education_id,
       d.degrees_family_norm,
       d.degrees, d.majors, d.minors, d.gpa,
       d.start_year, d.end_year,
       d.record_completeness_score,
       d.cluster_size,
       d.dup_cluster_status
  from cleansing_rad.education_duplicate d
  join sample_clusters s
    on s.person_id           =  d.person_id
   and s.school_id           is not distinct from d.school_id
   and s.degrees_family_norm is not distinct from d.degrees_family_norm
 order by d.person_id, d.school_id, d.degrees_family_norm,
          d.is_keep desc, d.record_completeness_score desc;


-- V-C. DUMP FOR A SPECIFIC STATUS with is_keep visible. Same shape as
--      education_duplicate V-C but ordered so the winner is the first
--      row of each cluster block. For the status values present, run
--      education_duplicate.sql V-A.
select dup_cluster_status,
       is_keep,
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
 where dup_cluster_status = 'Exact Duplicate'          -- CHANGE ME
 order by person_id,
          school_id nulls first,
          degrees_family_norm,
          is_keep desc,
          record_completeness_score desc,
          education_id;
