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


drop table if exists cleansing_rad.person_dedup_on_linkedin ;

create table cleansing_rad.person_dedup_on_linkedin AS
with ranked as (
  select p.id,
         p.linkedin_url,
         p.job_last_changed,
         p.job_last_verified,
         p.location_last_updated,
         row_number() over (
           partition by lower(p.linkedin_url)
               order by greatest(
                          coalesce(p.job_last_changed,      '1900-01-01'::timestamptz),
                          coalesce(p.job_last_verified,     '1900-01-01'::timestamptz),
                          coalesce(p.location_last_updated, '1900-01-01'::timestamptz)
                        ) desc,
                        p.pdl_id desc
         )                                                         as row_num
    from integration.person p
   where p.linkedin_url is not null
)
select id,
       linkedin_url,
       job_last_changed,
       job_last_verified,
       location_last_updated,
       row_num
  from ranked
 where row_num = 1

union all

select p.id,
       p.linkedin_url,
       p.job_last_changed,
       p.job_last_verified,
       p.location_last_updated,
       1                                                          as row_num
  from integration.person p
 where p.linkedin_url is null;