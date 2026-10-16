-- =============================================================================
-- V9__staging_pdl_person_experience_and_job_start_year_columns.sql
--
-- Applies the same year-only treatment as V8 (education) to:
--   - staging.pdl_person_experience_parsed.start_date / .end_date
--   - staging.pdl_person_parsed.job_start_date
--   - staging.pdl_person_unique.job_start_date (kept in lockstep with parsed)
--
-- Decision: store the year as int4 across the board for PDL date columns
-- where PDL ships partial formats. job_last_changed and job_last_verified
-- stay as date (system timestamps from PDL, always a full date — verified
-- against a full delivery).
--
-- What a full delivery showed:
--   - experience start_date: mostly yyyy-mm, some yyyy-only, rarely
--     yyyy-mm-dd. Partial values all became NULL under the old `date` cast.
--   - job_start_date: almost always a partial format, so likewise NULL
--     under the `date` cast.
--   - experience end_date: a similar partial-format distribution.
--
-- Both columns remain NULLABLE — PDL frequently omits the date entirely.
-- The dbt SELECTs read the raw value as text in JSON_TABLE / payload->>
-- and extract the year via substring(... from 1 for 4)::int4 in the outer
-- SELECT. substring(NULL ...) is NULL, so missing values pass through.
--
-- Companion: V8 made the same change for education_parsed. V9 finishes
-- the family. Schema source-of-truth: modeling/dbml/staging.dbml.
-- =============================================================================

-- pdl_person_experience_parsed: start_date / end_date  →  start_year / end_year
ALTER TABLE staging.pdl_person_experience_parsed
    DROP COLUMN start_date,
    DROP COLUMN end_date,
    ADD COLUMN start_year int4,
    ADD COLUMN end_year   int4;

COMMENT ON COLUMN staging.pdl_person_experience_parsed.start_year IS
    'Year extracted from PDL experience[].start_date. PDL sends '
    '"yyyy", "yyyy-mm", or "yyyy-mm-dd"; we keep only the year. '
    'NULL when PDL did not send a date.';

COMMENT ON COLUMN staging.pdl_person_experience_parsed.end_year IS
    'Year extracted from PDL experience[].end_date. NULL = current '
    'position OR PDL did not send a date. Same rule as start_year.';


-- pdl_person_parsed: job_start_date  →  job_start_year
-- (job_last_changed and job_last_verified stay as date — system timestamps)
ALTER TABLE staging.pdl_person_parsed
    DROP COLUMN job_start_date,
    ADD COLUMN job_start_year int4;

COMMENT ON COLUMN staging.pdl_person_parsed.job_start_year IS
    'Year extracted from PDL job_start_date. PDL sends "yyyy", '
    '"yyyy-mm", or "yyyy-mm-dd"; we keep only the year. NULL when '
    'PDL did not send a date.';


-- pdl_person_unique: same change, kept in lockstep with pdl_person_parsed
-- (its dbt model was not active yet when this migration landed, so the
-- ALTER was a no-op for data, but DBML / Flyway / dbt must stay coherent).
ALTER TABLE staging.pdl_person_unique
    DROP COLUMN job_start_date,
    ADD COLUMN job_start_year int4;

COMMENT ON COLUMN staging.pdl_person_unique.job_start_year IS
    'Year extracted from PDL job_start_date. Mirrors '
    'pdl_person_parsed.job_start_year.';
