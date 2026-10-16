-- =============================================================================
-- V24 — Inline company HQ address scalars onto integration.company; drop
--       integration.company_hq_address table entirely.
--
-- WHY:
-- V21 renamed integration.address → integration.company_hq_address,
-- establishing a per-company address table with a 1:1
-- relationship to integration.company. Verified against a full delivery:
-- every company has exactly one distinct address, and PDL emits
-- experience.company.location as a SINGLE OBJECT (never an array). The
-- separate company_hq_address table is
-- pure indirection — same logical row, one FK hop away, no information
-- value.
--
-- This is the same conclusion V20 reached for integration.person (Option
-- C — scalars on person, no person.address_id, no per-person row in
-- integration.address). Applying the same pattern to company:
--
--   integration.company.location_id      → ref.location  (KEEP — canonical hierarchy)
--   integration.company.latitude          numeric(9,6)   (NEW — inline scalar)
--   integration.company.longitude         numeric(9,6)   (NEW — inline scalar)
--   integration.company.postal_code       text           (NEW — inline scalar)
--   integration.company.street_address    text           (NEW — inline scalar)
--   integration.company.address_line_2    text           (NEW — inline scalar)
--   integration.company.address_id        → DROPPED
--   integration.company_hq_address        → DROPPED entirely (table + back-FK
--                                            relationships + Pattern 1 hooks)
--
-- Net result: integration.company carries its HQ address as 5 scalar
-- columns, mirroring integration.person's V20 Option C shape. Consumer
-- queries: 1 row, no JOIN. Schema consistency between person and company.
--
-- WHAT THIS DOES:
--   1. Drop the FK constraint integration.company.address_id → integration.
--      company_hq_address(id). Postgres auto-named it company_address_id_fkey
--      from the V6 inline `REFERENCES integration.address(id)` clause; the
--      V21 rename followed it by oid, so the constraint is still attached.
--   2. Drop the address_id column from integration.company.
--   3. Add 5 scalar columns to integration.company. Empty table → no
--      backfill needed.
--   4. Drop the integration.company_hq_address table entirely. The back-FK
--      we added in V21 (the implicit relationship via the pdl_company_id
--      JOIN key) was never a real Postgres FK constraint (intentional, to
--      avoid the referential cycle); only the dbt relationships test
--      enforced it. The table drops cleanly.
--
-- BLAST RADIUS:
--   - integration.company.address_id and integration.company_hq_address
--     are both EMPTY (company_hq_address was only populated while validating
--     the V21-V23 changes locally). Empty drops are instant.
--   - The dbt model for integration.company is rewritten alongside V24 to
--     inline the address-resolution CTE; no consumer code touches address_id
--     or company_hq_address.id yet.
--   - ADR-0009 FK drop/recreate: catalog._dropped_fks is emptied at on-
--     run-end of each dbt run, so the post-V24 dbt run won't try to
--     recreate the now-dead address_id FK.
--
-- DBML caveat: V24 is the canonical DDL; modeling/dbml/integration.dbml is
-- updated in the same change to (a) add the 5 scalar columns to the
-- integration.company block, (b) remove the integration.company_hq_address
-- table block entirely, (c) update the file header to drop company_hq_
-- address from the table list.
--
-- Why this didn't land as part of V21 originally: the V21 design started
-- from "rename integration.address" rather than asking "do we need a
-- separate address table at all?" The 1:1 cardinality only became clear
-- once a query against a full delivery confirmed one distinct address per
-- company and the source JSON was verified to be a single object, never an
-- array. V24 is the corrective design pivot.
-- =============================================================================

-- Step 1: drop the FK + column on integration.company
ALTER TABLE integration.company DROP CONSTRAINT IF EXISTS company_address_id_fkey;
ALTER TABLE integration.company DROP COLUMN     IF EXISTS address_id;

-- Step 2: add inline scalar columns
ALTER TABLE integration.company ADD COLUMN latitude       numeric(9,6);
ALTER TABLE integration.company ADD COLUMN longitude      numeric(9,6);
ALTER TABLE integration.company ADD COLUMN postal_code    text;
ALTER TABLE integration.company ADD COLUMN street_address text;
ALTER TABLE integration.company ADD COLUMN address_line_2 text;

COMMENT ON COLUMN integration.company.latitude IS
  'Parsed from PDL company.location.geo ("lat,lng"). Inline scalar per V24 — same Option C pattern as integration.person (V20).';
COMMENT ON COLUMN integration.company.longitude IS
  'Parsed from PDL company.location.geo. Inline scalar per V24.';
COMMENT ON COLUMN integration.company.postal_code IS
  'PDL company.location.postal_code. Inline scalar per V24.';
COMMENT ON COLUMN integration.company.street_address IS
  'PDL company.location.street_address. Inline scalar per V24.';
COMMENT ON COLUMN integration.company.address_line_2 IS
  'PDL company.location.address_line_2. Inline scalar per V24.';

-- Step 3: drop the no-longer-needed table
DROP TABLE IF EXISTS integration.company_hq_address;
