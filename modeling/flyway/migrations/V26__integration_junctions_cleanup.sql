-- =============================================================================
-- V26 — integration junction cleanup ahead of authoring the 11 PDL-populated
--       integration dbt models:
--
--       A. integration.person_education year-only switch — start_date/end_date
--          timestamptz → start_year/end_year int4. Mirrors V25's experience
--          pivot. PDL emits education[].start_date with year-only precision;
--          staging already carries int4. Was deferred from V25.
--
--       B. integration.person_language — add timestamp_created /
--          timestamp_modified. Original V6 baseline omitted them; every other
--          integration.* junction has them. Convention cleanup.
--
--       C. integration.experience_industry — same as B (omitted in V6).
--
-- BLAST RADIUS:
--   - All three tables are EMPTY (no dbt model has populated any
--     integration junction yet — those models are authored alongside V26).
--     All column changes are instant.
--   - integration.person_education start_date / end_date have no consumers
--     yet (no dbt model, no downstream view). DROP + ADD safe.
--   - Adding timestamp_created / timestamp_modified with default now() is
--     instant on an empty table.
--   - dbt_project.yml Pattern 1 hooks for the 11 PDL-populated junctions
--     are added in the same change (V6 baseline never had them since there
--     were no models).
--   - DBML (integration.dbml) updated in the same change to reflect the
--     final shape.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A. integration.person_education — year-only switch (V25 pattern)
-- -----------------------------------------------------------------------------

ALTER TABLE integration.person_education DROP COLUMN IF EXISTS start_date;
ALTER TABLE integration.person_education DROP COLUMN IF EXISTS end_date;

ALTER TABLE integration.person_education ADD COLUMN start_year int4;
ALTER TABLE integration.person_education ADD COLUMN end_year   int4;

COMMENT ON COLUMN integration.person_education.start_year IS
  'Year education started (4-digit). PDL emits education[].start_date with year-only precision; staging carries int4 to match. NULL when PDL emitted no start_date. Was timestamptz pre-V26.';
COMMENT ON COLUMN integration.person_education.end_year IS
  'Year education ended (4-digit). NULL when PDL emitted no end_date. Was timestamptz pre-V26.';

-- -----------------------------------------------------------------------------
-- B. integration.person_language — add timestamp columns (convention cleanup)
-- -----------------------------------------------------------------------------

ALTER TABLE integration.person_language
  ADD COLUMN timestamp_created  timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN timestamp_modified timestamptz NOT NULL DEFAULT now();

-- -----------------------------------------------------------------------------
-- C. integration.experience_industry — add timestamp columns
-- -----------------------------------------------------------------------------

ALTER TABLE integration.experience_industry
  ADD COLUMN timestamp_created  timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN timestamp_modified timestamptz NOT NULL DEFAULT now();
