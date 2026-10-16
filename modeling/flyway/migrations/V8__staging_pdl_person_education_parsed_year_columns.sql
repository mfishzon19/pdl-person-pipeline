-- =============================================================================
-- V8__staging_pdl_person_education_parsed_year_columns.sql
--
-- Replaces date-typed start_date / end_date columns on
-- staging.pdl_person_education_parsed with year-only int4 columns
-- (start_year / end_year). Reason: PDL ships education dates as "yyyy", "yyyy-mm", or "yyyy-mm-dd" with year-only being the
-- common case. The old `date` cast dropped year-only values through
-- NULL ON ERROR; storing the year directly preserves the data.
--
-- Both columns remain NULLABLE — PDL frequently omits the date entirely
-- (real-data sample: many entries have no start_date or end_date at all).
-- See processing/dbt/models/staging/pdl_person/pdl_person_education_parsed.sql
-- for the upstream extraction (substring + cast).
--
-- The staging table is populated by dbt with materialized='incremental' +
-- pre_hook=TRUNCATE + on_schema_change='fail'. After this migration,
-- the next dbt build will TRUNCATE + repopulate with the new shape.
--
-- Schema source-of-truth: modeling/dbml/staging.dbml — block
-- `staging.pdl_person_education_parsed`. This migration matches the
-- DBML edit made in the same change.
-- =============================================================================

ALTER TABLE staging.pdl_person_education_parsed
    DROP COLUMN start_date,
    DROP COLUMN end_date,
    ADD COLUMN start_year int4,
    ADD COLUMN end_year   int4;

COMMENT ON COLUMN staging.pdl_person_education_parsed.start_year IS
    'Year extracted from PDL education[].start_date. PDL sends '
    '"yyyy", "yyyy-mm", or "yyyy-mm-dd"; we keep only the year. '
    'NULL when PDL did not send a date.';

COMMENT ON COLUMN staging.pdl_person_education_parsed.end_year IS
    'Year extracted from PDL education[].end_date. Same rule as '
    'start_year.';
