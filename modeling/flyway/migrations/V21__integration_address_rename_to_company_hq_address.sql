-- =============================================================================
-- V21 — Rename integration.address → integration.company_hq_address.
--       Add pdl_company_id natural-key column as a dbt-DAG join aid.
--
-- WHY:
-- V20 ended integration.address's role as a shared person/company resource:
-- integration.person now carries scalar latitude / longitude / postal_code
-- directly (Option C). The table is functionally
-- company-HQ-only from V20 onward, so rename it to reflect actual scope.
--
-- ADD COLUMN pdl_company_id (text, UNIQUE NOT NULL):
-- integration.company.address_id and integration.company_hq_address.id are
-- both dbt-computed ROW_NUMBER values (per ADR-0010) and not stable across
-- rebuilds. The dbt model that builds integration.company needs a stable
-- natural key on company_hq_address to JOIN on for address_id resolution.
-- pdl_company_id serves that purpose — same value as
-- integration.company.pdl_company_id. No FK constraint (would create a
-- cycle with integration.company.address_id → company_hq_address.id);
-- referential integrity is enforced by dbt relationships tests.
--
-- WHAT THIS DOES:
--   1. ALTER TABLE RENAME — propagates automatically to:
--      - the PK constraint name (Postgres renames address_pkey →
--        company_hq_address_pkey by following the table)
--      - FK from integration.company.address_id (the constraint stores the
--        target by oid, not by name; rename is transparent)
--   2. RENAME INDEX — secondary indexes are not auto-renamed by table rename;
--      explicit ALTER INDEX is required.
--   3. ADD COLUMN pdl_company_id text NOT NULL — safe on the empty table
--      (never populated by any dbt model since integration.address was
--      created in the V6 baseline).
--   4. ADD CONSTRAINT UNIQUE on pdl_company_id — Postgres auto-names this
--      <table>_<column>_key per its convention.
--
-- BLAST RADIUS:
--   - Empty table (V20-and-prior never populated integration.address from
--     any dbt model). NOT NULL on the new column
--     is therefore safe — no backfill required.
--   - integration.company.address_id FK constraint follows the table rename
--     without surgery (Postgres FK targets are by oid).
--   - No data loss; the table identity is preserved (same oid, just a new
--     name in pg_class).
--   - integration.company has not yet been populated by any dbt model
--     (that lands alongside this migration), so no consumer disruption.
-- =============================================================================

ALTER TABLE integration.address                 RENAME TO company_hq_address;
ALTER INDEX integration.idx_address_location_id RENAME TO idx_company_hq_address_location_id;

ALTER TABLE integration.company_hq_address ADD COLUMN pdl_company_id text NOT NULL;
ALTER TABLE integration.company_hq_address
  ADD CONSTRAINT company_hq_address_pdl_company_id_key UNIQUE (pdl_company_id);

COMMENT ON TABLE integration.company_hq_address IS
  'Company HQ street-level address. Renamed from integration.address in V21. One row per integration.company by construction (verified against a full delivery: every company had exactly one distinct address across all experience entries). pdl_company_id is a dbt-DAG join key (NOT a consumer interface) — reach the address via integration.company.address_id → integration.company_hq_address.id.';

COMMENT ON COLUMN integration.company_hq_address.pdl_company_id IS
  'PDL natural key — same value as integration.company.pdl_company_id. UNIQUE NOT NULL. Carried on this table only as a JOIN key for the dbt DAG (integration.company SELECT JOINs on it to resolve address_id). No FK constraint — would create a referential cycle with integration.company.address_id. Implicit constraint enforced by dbt relationships tests.';
