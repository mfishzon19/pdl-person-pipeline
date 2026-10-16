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


---------------- Experience-row duplicate classification --------------------

-- Builds cleansing_rad.experience_duplicate — every row of every same
-- person + same company + same normalized-title cluster of ≥2 rows,
-- annotated with a cluster-level status describing the RELATIONSHIP
-- SHAPE among the cluster's rows.
--
-- Goal of this pass: SURFACE THE TAXONOMY of duplicate patterns so
-- downstream we can decide handling per shape. `is_keep` is populated
-- as NULL — row-level keep/drop rules are a later pass.
--
-- Cluster key: (person_id, company_id, lower(trim(title))). Postgres
-- treats NULL = NULL in PARTITION BY, so null-company rows cluster with
-- other null-company rows (same person + same title), and null-title
-- rows cluster with other null-title rows (same person + same company).


-- dup_cluster_status --------------------------------------------------------
--
-- Cluster-level classification. Every row in a cluster shares the same
-- status string. Describes the RELATIONSHIP shape present among the
-- cluster's rows plus flags for null key columns.
--
-- BASE LABELS
--
--   Null Company
--     Every row in the cluster has company_id IS NULL. The employer
--     can't be identified — the whole cluster is unusable from an
--     identity perspective. Under the current cluster key, if any row
--     has null company then ALL rows in the cluster do (company_id is
--     part of the key).
--
--   Null Title
--     Every row in the cluster has title IS NULL. Same shape as
--     Null Company — title is part of the key, so this fires when the
--     cluster is homogeneously null-title.
--
--   Exact Duplicate
--     At least one pair of rows has IDENTICAL year ranges (same
--     start_year AND same end_year, both non-null). Purest duplicate
--     case — same tenure recorded twice.
--
--   Superset/Subset
--     At least one pair has STRICT containment — one row's range fully
--     contains the other's (start ≤ other's start AND end ≥ other's
--     end, with at least one strict inequality; not identical). Typical
--     shape: a wide "was there 2015-2023" record contains a narrower
--     "was there 2018-2020" record.
--
--   Overlap Tenure
--     At least one pair has partial overlap (ranges overlap but neither
--     contains the other), OR at least one row has NULL start_year or
--     NULL end_year (permissive read: an unknown range could overlap,
--     so it counts here).
--
--   Disjoined Tenure
--     At least one pair has ranges that DON'T overlap — either a gap
--     (2015-2018 then 2020-2022) or boundary-touching sequential
--     (2015-2020 then 2020-2023). Both read as separate stints /
--     re-hires.
--
-- COMPOUND STATUS
--
-- Every applicable label is concatenated with " + " in fixed order
-- (null-key flags first, then relationships from most-specific to
-- least-specific):
--
--   Null Company + Null Title + Exact Duplicate + Superset/Subset
--     + Overlap Tenure + Disjoined Tenure
--
-- Skip labels absent from the cluster. Examples:
--
--   All rows null company, one pair identical              → "Null Company + Exact Duplicate"
--   All rows null company, containment pair                → "Null Company + Superset/Subset"
--   All null title, sequential ranges                      → "Null Title + Disjoined Tenure"
--   All null company AND all null title, partial overlap   → "Null Company + Null Title + Overlap Tenure"
--   Real company + real title, only containment            → "Superset/Subset"
--   Real company + real title, containment + disjoined     → "Superset/Subset + Disjoined Tenure"


-- Other output columns ------------------------------------------------------
--
--   record_completeness_score  (0-9)
--     Per-row score of how much evidence each record carries. Not used
--     in dup_cluster_status. Reserved for future is_keep logic.
--     Scoring:
--       +1 title populated
--       +1 summary populated
--       +1 start_year populated
--       +1 end_year populated
--       +1 title_class_id populated
--       +1 title_role_id populated
--       +1 title_sub_role_id populated
--       +1 length(title)  >= 20
--       +1 length(summary) >= 50
--     is_primary is NOT scored — it marks "person's current job", not
--     "canonical row for this tenure".
--
--   cluster_size
--     Number of rows in the (person_id, company_id, normalized_title)
--     cluster. Always ≥ 2 for rows in this table.
--
--   is_keep  (bool, NULL)
--     Deferred. Left NULL at this pass. Once dup_cluster_status is used
--     to design per-shape handling rules, is_keep will be populated to
--     mark row-level winner/loser.


-- DEPENDENCIES: integration.experience, ref.job_title_class,
--               ref.job_title_role, ref.job_title_subrole.
--
-- V-checks below (V-A, V-B, V-C) are VERIFICATION queries — read-only
-- spot-checks confirming the build did what we think it did + surfacing
-- the taxonomy distribution. Run after any rebuild.


-- BUILD ----------------------------------------------------------------------

drop table if exists cleansing_rad.experience_duplicate cascade;

create table cleansing_rad.experience_duplicate as
with scored as (
  --Every row in integration.experience with completeness score + ref
  --names. Null-title rows are INCLUDED — they cluster with other
  --null-title rows for the same person + company and get a "Null Title"
  --label in the compound status.
  select e.id                                                                          as experience_id,
         e.person_id,
         e.company_id,
         e.title,
         e.summary,
         e.is_primary,
         e.start_year,
         e.end_year,
         e.experience_idx,
         cls.name                                                                       as title_class_name,
         rol.name                                                                       as title_role_name,
         sub.name                                                                       as title_sub_role_name,
         (case when e.title             is not null then 1 else 0 end
        + case when e.summary           is not null then 1 else 0 end
        + case when e.start_year        is not null then 1 else 0 end
        + case when e.end_year          is not null then 1 else 0 end
        + case when e.title_class_id    is not null then 1 else 0 end
        + case when e.title_role_id     is not null then 1 else 0 end
        + case when e.title_sub_role_id is not null then 1 else 0 end
        + case when length(e.title)  >= 20         then 1 else 0 end
        + case when length(e.summary) >= 50        then 1 else 0 end
         )                                                                              as record_completeness_score
    from integration.experience     e
    left join ref.job_title_class   cls on cls.id = e.title_class_id
    left join ref.job_title_role    rol on rol.id = e.title_role_id
    left join ref.job_title_subrole sub on sub.id = e.title_sub_role_id
),
clustered as (
  select s.*,
         count(*) over w                        as cluster_size,
         bool_and(s.company_id is null) over w  as cluster_company_all_null,
         bool_and(s.title      is null) over w  as cluster_title_all_null
    from scored s
   window w as (partition by s.person_id, s.company_id, lower(trim(s.title)))
),
in_clusters as (
  select * from clustered where cluster_size > 1
),
pair_flags as (
  --For each row, aggregate pair-level relationship flags against every
  --other row in its cluster (self-join, b.experience_id <> a.experience_id).
  select
    a.experience_id,
    a.person_id,
    a.company_id,
    a.title,
    a.summary,
    a.is_primary,
    a.start_year,
    a.end_year,
    a.experience_idx,
    a.title_class_name,
    a.title_role_name,
    a.title_sub_role_name,
    a.record_completeness_score,
    a.cluster_size,
    a.cluster_company_all_null,
    a.cluster_title_all_null,
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
    on b.person_id  = a.person_id
   and b.company_id is not distinct from a.company_id
   and lower(trim(b.title)) is not distinct from lower(trim(a.title))
   and b.experience_id     <> a.experience_id
  group by
    a.experience_id, a.person_id, a.company_id, a.title, a.summary, a.is_primary,
    a.start_year, a.end_year, a.experience_idx,
    a.title_class_name, a.title_role_name, a.title_sub_role_name,
    a.record_completeness_score, a.cluster_size,
    a.cluster_company_all_null, a.cluster_title_all_null
)
select experience_id,
       person_id,
       company_id,
       title,
       summary,
       is_primary,
       start_year,
       end_year,
       experience_idx,
       title_class_name,
       title_role_name,
       title_sub_role_name,
       record_completeness_score,
       cluster_size,
       nullif(
         concat_ws(
           ' + ',
           case when cluster_company_all_null then 'Null Company'    end,
           case when cluster_title_all_null   then 'Null Title'      end,
           case when has_exact_duplicate      then 'Exact Duplicate' end,
           case when has_superset_subset      then 'Superset/Subset' end,
           case when has_overlap_tenure       then 'Overlap Tenure'  end,
           case when has_disjoined_tenure     then 'Disjoined Tenure' end
         ), ''
       )                                                                                as dup_cluster_status,
       null::bool                                                                       as is_keep
  from pair_flags;


-- INDEXES / STATS -----------------------------------------------------------

alter table cleansing_rad.experience_duplicate
  add constraint experience_duplicate_pkey primary key (experience_id);

create index experience_duplicate_person_company_idx on cleansing_rad.experience_duplicate (person_id, company_id);
create index experience_duplicate_cluster_size_idx   on cleansing_rad.experience_duplicate (cluster_size);
create index experience_duplicate_status_idx         on cleansing_rad.experience_duplicate (dup_cluster_status);
create index experience_duplicate_is_keep_idx        on cleansing_rad.experience_duplicate (is_keep);

analyze cleansing_rad.experience_duplicate;


-- CHECKS --------------------------------------------------------------------

-- V-A. Cluster count per dup_cluster_status — top-line taxonomy. This is
--      the key query: it says what shapes of duplicates exist and how
--      many of each. Downstream design of is_keep + collapse rules
--      should be driven by this distribution.
select dup_cluster_status,
       count(distinct (person_id, company_id, lower(trim(title))))     as clusters,
       count(*)                                                        as rows
  from cleansing_rad.experience_duplicate
 group by dup_cluster_status
 order by clusters desc;


-- V-B. Sample cluster per status — one example of each status, all rows.
--      Eyeball to confirm the classifier is right and to develop intuition
--      about each shape.
with one_per_status as (
  select distinct on (dup_cluster_status)
         dup_cluster_status, person_id, company_id, lower(trim(title)) as title_norm
    from cleansing_rad.experience_duplicate
   order by dup_cluster_status, random()
)
select d.dup_cluster_status,
       d.person_id, d.company_id, d.experience_id,
       d.title, d.start_year, d.end_year, d.experience_idx,
       d.title_class_name, d.title_role_name, d.title_sub_role_name,
       d.is_primary, d.record_completeness_score, d.cluster_size
  from cleansing_rad.experience_duplicate d
  join one_per_status s
    on s.person_id  = d.person_id
   and s.company_id is not distinct from d.company_id
   and s.title_norm is not distinct from lower(trim(d.title))
 order by d.dup_cluster_status, d.person_id, d.company_id, d.record_completeness_score desc;


-- V-C. Single-sub-role versions of V-A and V-B, restricted to one PDL
--      job-title sub-role so a review can focus on one population.
--      Change the `title_sub_role_name = '…'` literal (any value from
--      ref.job_title_subrole) to the population you want to review.

-- V-C.1 — per-sub-role taxonomy count (mirror of V-A)
select dup_cluster_status,
       count(distinct (person_id, company_id, lower(trim(title))))     as subrole_clusters,
       count(*)                                                        as subrole_rows
  from cleansing_rad.experience_duplicate
 where title_sub_role_name = 'software'
 group by dup_cluster_status
 order by subrole_clusters desc;


-- V-C.2 — per-sub-role sample cluster per status (mirror of V-B).
with subrole_clusters as (
  select distinct dup_cluster_status, person_id, company_id, lower(trim(title)) as title_norm
    from cleansing_rad.experience_duplicate
   where title_sub_role_name = 'software'
),
one_subrole_per_status as (
  select distinct on (dup_cluster_status)
         dup_cluster_status, person_id, company_id, title_norm
    from subrole_clusters
   order by dup_cluster_status, random()
)
select d.dup_cluster_status,
       d.person_id, d.company_id, d.experience_id,
       d.title, d.start_year, d.end_year, d.experience_idx,
       d.title_class_name, d.title_role_name, d.title_sub_role_name,
       d.is_primary, d.record_completeness_score, d.cluster_size
  from cleansing_rad.experience_duplicate d
  join one_subrole_per_status s
    on s.person_id  = d.person_id
   and s.company_id is not distinct from d.company_id
   and s.title_norm is not distinct from lower(trim(d.title))
 order by d.dup_cluster_status, d.person_id, d.company_id, d.record_completeness_score desc;


-- V-C.3 — DUMP FOR A SPECIFIC STATUS (all sub-roles). Change the
--         `dup_cluster_status = '…'` value to the bucket you want to
--         review. Every row in every matching cluster is returned,
--         sorted by cluster key.
--
--         Run V-A first to list the status combinations present in your
--         data. Any non-empty combination of the six base labels can
--         occur (always in the fixed order above); see the examples in
--         the COMPOUND STATUS header.
select dup_cluster_status,
       person_id,
       company_id,
       lower(trim(title)) as title_norm,
       experience_id,
       title,
       start_year,
       end_year,
       experience_idx,
       title_class_name,
       title_role_name,
       title_sub_role_name,
       is_primary,
       record_completeness_score,
       cluster_size
  from cleansing_rad.experience_duplicate
 where dup_cluster_status  = 'Superset/Subset'          -- CHANGE ME
 order by person_id,
          company_id nulls first,
          lower(trim(title)),
          record_completeness_score desc,
          experience_id;
