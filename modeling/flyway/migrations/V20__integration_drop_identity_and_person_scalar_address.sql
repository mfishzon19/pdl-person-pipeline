-- =============================================================================
-- V20 — Integration: DROP IDENTITY across all integration.* tables
--       (ADR-0010, extending ADR-0008 from ref.* to integration.*)
--       + replace integration.person.address_id with scalar
--       latitude / longitude / postal_code.
--
-- TWO BUNDLED CHANGES (both needed before the first integration dbt model lands):
--
-- 1. DROP IDENTITY across integration.*
--    Same rationale as V14 for ref.*. dbt-postgres's default `incremental +
--    append + on_schema_change='fail'` workflow requires the dbt SELECT to
--    project every destination column — including `id`. Tables with
--    `GENERATED ALWAYS AS IDENTITY` reject explicit id values from the dbt
--    SELECT and also drift-fail the schema-equality check. Dropping IDENTITY
--    lets each integration dbt model compute `id` via ROW_NUMBER OVER (ORDER
--    BY <natural_key>), same pattern V14 established for ref.*.
--
--    All 6 integration tables with `id bigint GENERATED ALWAYS AS IDENTITY
--    PRIMARY KEY` lose the IDENTITY clause atomically (one migration) —
--    avoids an in-between state where some integration tables are dbt-id'd
--    and others are DB-id'd. PRIMARY KEY constraint is preserved; the column
--    becomes plain `bigint NOT NULL PRIMARY KEY`.
--
--    All 6 tables are empty today (no integration model has been
--    populated yet) — zero data risk.
--
--    Junction tables (integration.person_country, person_skill, etc.) have
--    composite PKs (no surrogate `id`), so they're unaffected and excluded
--    from this list.
--
-- 2. Replace integration.person.address_id with scalar lat/long/postal_code
--    Per the address-modeling decision (docs/data_model/12_location.md
--    §4.7): the PDL person tier has no
--    street-level data, so integration.person's "address" is fundamentally
--    just (lat, long, postal_code) scalars carried from the person_home row
--    in staging.pdl_person_addresses_unique. The shared integration.address
--    table is reserved for company-HQ data (where PDL DOES emit street-level
--    detail), so person.address_id is dead weight. This migration:
--
--      a. Drops the FK constraint person.address_id → integration.address(id).
--      b. Drops idx_person_address_id.
--      c. Drops the person.address_id column.
--      d. Adds person.latitude / longitude (numeric(9,6)) + postal_code (text).
--         Parsed from PDL location.geo "lat,lng" in the integration.person
--         dbt SELECT.
--
--    integration.address itself stays (it will become company-HQ-only once
--    integration.company lands; V21 renames it to
--    company_hq_address).
--
-- BLAST RADIUS:
--   - 6 ALTER COLUMN id DROP IDENTITY — empty tables, instant.
--   - person.address_id FK / index / column drops — empty table, instant.
--   - 3 ADD COLUMN on integration.person — empty table, no rewrite needed.
--   - No cross-schema impact: ref.* unaffected; staging.* unaffected;
--     catalog.* unaffected.
--   - Future integration dbt models adopt the ref-pattern SELECT shape;
--     the integration block in dbt_project.yml is already wired for it.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. DROP IDENTITY — 6 integration tables
-- -----------------------------------------------------------------------------

ALTER TABLE integration.address                          ALTER COLUMN id DROP IDENTITY;
ALTER TABLE integration.person                           ALTER COLUMN id DROP IDENTITY;
ALTER TABLE integration.company                          ALTER COLUMN id DROP IDENTITY;
ALTER TABLE integration.school                           ALTER COLUMN id DROP IDENTITY;
ALTER TABLE integration.experience                       ALTER COLUMN id DROP IDENTITY;
ALTER TABLE integration.person_education                 ALTER COLUMN id DROP IDENTITY;

-- -----------------------------------------------------------------------------
-- 2. Replace integration.person.address_id with scalar lat / long / postal_code
-- -----------------------------------------------------------------------------

-- Drop the FK constraint first; Postgres names it as the column's REFERENCES
-- auto-generated name from V6. V6 didn't pin a CONSTRAINT name, so Postgres
-- assigned `person_address_id_fkey`. Use IF EXISTS for resilience.
ALTER TABLE integration.person DROP CONSTRAINT IF EXISTS person_address_id_fkey;

DROP INDEX  IF EXISTS integration.idx_person_address_id;
ALTER TABLE integration.person DROP COLUMN IF EXISTS address_id;

ALTER TABLE integration.person ADD COLUMN latitude    numeric(9,6);
ALTER TABLE integration.person ADD COLUMN longitude   numeric(9,6);
ALTER TABLE integration.person ADD COLUMN postal_code text;

COMMENT ON COLUMN integration.person.latitude IS
  'Parsed from PDL location.geo ("lat,lng") for the person_home row (source_idx=0) in staging.pdl_person_addresses_unique.';
COMMENT ON COLUMN integration.person.longitude IS
  'Parsed from PDL location.geo. Same person_home source row as latitude.';
COMMENT ON COLUMN integration.person.postal_code IS
  'PDL location.postal_code for the person_home address. NULL when PDL emits no postal data.';
