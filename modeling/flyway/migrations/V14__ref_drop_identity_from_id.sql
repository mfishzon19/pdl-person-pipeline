-- =============================================================================
-- V14 — Drop GENERATED ALWAYS AS IDENTITY from ref.* `id` columns
--
-- WHY:
-- V4 (ref baseline) created every ref table with
-- `id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY`. That works for
-- standalone INSERTs but breaks dbt-postgres's default `incremental +
-- append` strategy: the default INSERT generator references `dest_columns`
-- (the target's full column list, including `id` + `timestamp_*`), but
-- the dbt model SELECTs don't (and can't) produce those values. The
-- INSERT errors with "column id does not exist in temp_relation."
--
-- The previously-explored fix was a project-wide macro override
-- (processing/dbt/macros/get_incremental_append_sql.sql) that swapped
-- `dest_columns` for `temp_relation.columns`. That worked but required
-- pairing every ref model with `on_schema_change='ignore'` to skip the
-- dbt schema-equality check — which punctured the project-wide drift
-- detector (`on_schema_change=fail` per ADR-0001).
--
-- This migration takes the opposite approach: drop the DB-side IDENTITY
-- on ref `id` columns so dbt can supply values explicitly (via
-- ROW_NUMBER() OVER (...) in the model SELECT). The dbt SELECT now
-- produces the full target shape — `on_schema_change=fail` works on
-- ref models the same way it works on staging. The macro override is
-- no longer needed and is deleted alongside this migration.
--
-- WHAT THIS DOES:
-- `ALTER COLUMN id DROP IDENTITY` removes the GENERATED clause but keeps
-- the column as plain `bigint NOT NULL PRIMARY KEY`. Existing rows
-- retain their previously-assigned id values; future INSERTs must
-- supply ids explicitly. Sequence backing the IDENTITY is dropped by
-- Postgres automatically.
--
-- BLAST RADIUS:
--   - PRIMARY KEY constraint on id stays — no functional change to
--     uniqueness or referential integrity.
--   - Foreign keys from other ref tables (state_province → country,
--     city → country / state_province, location → all of them, etc.)
--     reference id by value, not by mechanism. No FK changes needed.
--   - V5 COALESCE-based UNIQUE indexes on ref.city / ref.location
--     reference id values, unaffected.
--   - Existing data is preserved. After V14 applies, the
--     next dbt rebuild (TRUNCATE + INSERT) will replace those values
--     with dbt-computed ROW_NUMBER ids — fine, surrogate IDs are
--     explicitly documented as not stable across rebuilds.
--
-- 16 ALTER statements — one per ref table in the V4 baseline. Done in
-- a single migration so the change is atomic: either every ref table
-- loses IDENTITY together or none do (avoids an in-between state where
-- some tables are dbt-id'd and others are DB-id'd).
-- =============================================================================

ALTER TABLE ref.continent              ALTER COLUMN id DROP IDENTITY;
ALTER TABLE ref.country                ALTER COLUMN id DROP IDENTITY;
ALTER TABLE ref.state_province         ALTER COLUMN id DROP IDENTITY;
ALTER TABLE ref.city                   ALTER COLUMN id DROP IDENTITY;
ALTER TABLE ref.metro                  ALTER COLUMN id DROP IDENTITY;
ALTER TABLE ref.location               ALTER COLUMN id DROP IDENTITY;
ALTER TABLE ref.industry               ALTER COLUMN id DROP IDENTITY;
ALTER TABLE ref.industry_v2            ALTER COLUMN id DROP IDENTITY;
ALTER TABLE ref.job_title_class        ALTER COLUMN id DROP IDENTITY;
ALTER TABLE ref.job_title_role         ALTER COLUMN id DROP IDENTITY;
ALTER TABLE ref.job_title_subrole      ALTER COLUMN id DROP IDENTITY;
ALTER TABLE ref.job_title_classification ALTER COLUMN id DROP IDENTITY;
ALTER TABLE ref.seniority_level        ALTER COLUMN id DROP IDENTITY;
ALTER TABLE ref.skill                  ALTER COLUMN id DROP IDENTITY;
ALTER TABLE ref.interest               ALTER COLUMN id DROP IDENTITY;
ALTER TABLE ref.language               ALTER COLUMN id DROP IDENTITY;
