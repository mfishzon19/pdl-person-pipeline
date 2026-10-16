-- =============================================================================
-- V17 — Add 3 PDL freshness signal columns to staging.pdl_person_unique
--
-- Follow-on to V16. V16 added job_last_changed / job_last_verified /
-- location_last_updated to integration.person as real per-record PDL
-- freshness signals (replacing the dead first_seen / num_sources /
-- num_records the original design assumed). But staging.pdl_person_unique
-- was untouched by V16 and still didn't carry these columns through from
-- staging.pdl_person_parsed — meaning the upcoming integration.person dbt
-- model would have to re-derive them by joining back to pdl_person_parsed
-- and duplicating the alias-resolution + dedup logic.
--
-- This migration closes that gap: pdl_person_unique now carries the 3
-- freshness columns straight through (verbatim DISTINCT ON winner), so
-- integration.person reads them from the deduplicated source without
-- re-dedup work.
--
-- Types: `date` at staging (matching staging.pdl_person_parsed) — PDL emits
-- these as date-only values, no time component. The integration.person
-- columns are timestamptz; the cast happens at the integration dbt model.
--
-- Population: most but not all persons carry these signals (see
-- docs/data_model/14_sources.md §2). Identity-resolution +
-- job-history-recency logic must adopt an explicit NULL strategy for the
-- persons without them when those features are built.
--
-- All NULL on apply; populated on next pdl_person_unique rebuild via the
-- updated dbt model SELECT.
-- =============================================================================

ALTER TABLE staging.pdl_person_unique
  ADD COLUMN job_last_changed      date,
  ADD COLUMN job_last_verified     date,
  ADD COLUMN location_last_updated date;
