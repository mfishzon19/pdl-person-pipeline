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


---------------- Person-education row-norm sidecar -------------------------

-- Builds cleansing_rad.pe_norm — a narrow projection of
-- integration.person_education with the two derived-key columns
-- downstream cleansing needs (degrees_family_norm, degrees_family_count)
-- + basic FK cols + a record completeness score. Sole purpose is
-- performance: downstream V-checks (V-D, V-E, V-G in education_duplicate;
-- V-C in education_null_degree_rescue) were spending tens of seconds
-- per run recomputing degrees_family_norm from a jsonb-array subquery
-- over the whole table. Precomputing it once + indexing (person, school,
-- years) drops those V-checks to seconds.
--
-- Cost of maintaining pe_norm:
--   One full-scan build (dominated by the same jsonb-array subquery, run
--   ONCE instead of per query), plus the storage for a narrow copy of
--   every person_education row.
--
-- REBUILD TRIGGER
--   Any change to integration.person_education OR
--   cleansing_rad.degree_family invalidates pe_norm. Rebuild after either.
--
-- USAGE (canonical example, replacing an inline CTE):
--
--     -- BEFORE — slow, recomputes over the full table per join side
--     with pe_n as (
--       select pe.id, pe.person_id, pe.school_id, pe.start_year, pe.end_year,
--              (select string_agg(distinct df.family, '|' order by df.family)
--                 from jsonb_array_elements_text(pe.degrees) x
--                 join cleansing_rad.degree_family df on df.canonical_form = lower(trim(x))
--              ) as degrees_family_norm
--         from integration.person_education pe
--        where pe.school_id  is not null
--          and pe.start_year is not null
--          and pe.end_year   is not null
--     )
--     select ... from pe_n a join pe_n b on ...;
--
--     -- AFTER — read directly, no CTE, uses the (person, school, years) index
--     select ... from cleansing_rad.pe_norm a join cleansing_rad.pe_norm b on ...
--      where a.school_id is not null and a.start_year is not null and a.end_year is not null
--        and b.school_id is not null and b.start_year is not null and b.end_year is not null;
--
-- NOTE: pe_norm is NARROW — no degrees/majors/minors/summary jsonb bodies
-- (kept out to keep the table small so it stays cache-warm). Sampling
-- queries that need those columns should join back to
-- integration.person_education on id.
--
-- DEPENDENCIES: integration.person_education, cleansing_rad.degree_family.


-- BUILD ----------------------------------------------------------------------

drop table if exists cleansing_rad.pe_norm cascade;

create table cleansing_rad.pe_norm as
select pe.id,
       pe.person_id,
       pe.school_id,
       pe.start_year,
       pe.end_year,
       (select string_agg(distinct df.family, '|' order by df.family)
          from jsonb_array_elements_text(pe.degrees) x
          join cleansing_rad.degree_family df on df.canonical_form = lower(trim(x))
       )                                                                        as degrees_family_norm,
       (select count(distinct df.family)::int
          from jsonb_array_elements_text(pe.degrees) x
          join cleansing_rad.degree_family df on df.canonical_form = lower(trim(x))
       )                                                                        as degrees_family_count,
       coalesce(case when jsonb_typeof(pe.majors) = 'array'
                     then jsonb_array_length(pe.majors) end, 0)                  as majors_count,
       (pe.degrees is not null and jsonb_typeof(pe.degrees) = 'array'
        and jsonb_array_length(pe.degrees) > 0)                                  as has_degrees,
       (pe.majors is not null and jsonb_typeof(pe.majors) = 'array'
        and jsonb_array_length(pe.majors) > 0)                                   as has_majors,
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
       )                                                                        as record_completeness_score
  from integration.person_education pe;


-- INDEXES / STATS -----------------------------------------------------------

alter table cleansing_rad.pe_norm add constraint pe_norm_pkey primary key (id);

-- Composite for the V-D/V-E self-join and the rescue's "same (person,
-- school) with matching years" scan. Partial (school+start+end
-- non-null) keeps it lean — pairs at same-year require all three.
create index pe_norm_ps_years_idx
  on cleansing_rad.pe_norm (person_id, school_id, start_year, end_year)
 where school_id is not null and start_year is not null and end_year is not null;

-- Fallback for rescue rules that overlap-check across years — need
-- (person, school) without demanding non-null years.
create index pe_norm_person_school_idx
  on cleansing_rad.pe_norm (person_id, school_id)
 where school_id is not null;

analyze cleansing_rad.pe_norm;


-- CHECKS --------------------------------------------------------------------

-- V-A. Row count + null-key distribution.
select count(*)                                       as total_rows,
       count(*) filter (where school_id is null)      as null_school_rows,
       count(*) filter (where degrees_family_norm is null) as null_family_rows,
       count(*) filter (where start_year is null or end_year is null) as null_years_rows,
       count(*) filter (where has_degrees)            as with_degrees_rows,
       count(*) filter (where has_majors)             as with_majors_rows
  from cleansing_rad.pe_norm;


-- V-B. degrees_family_norm distribution.
select degrees_family_norm,
       count(*) as rows
  from cleansing_rad.pe_norm
 group by degrees_family_norm
 order by rows desc
 limit 20;
