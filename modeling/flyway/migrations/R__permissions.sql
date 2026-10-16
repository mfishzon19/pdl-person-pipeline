-- =============================================================================
-- R__permissions.sql — schema ownership for the local PDL database.
--
-- HAND-AUTHORED. Repeatable migration: Flyway re-runs whenever this file's
-- checksum changes. Idempotent — every statement converges to the same
-- end-state on re-run.
--
-- Model (local-only, single owner):
--   The login role Flyway connects as (docker-compose creates `pdl_etl`,
--   password `pdl_etl_dev`, database `pdl_etl`) owns the database and every managed
--   schema. It has implicit ALL on all objects via ownership, so no explicit
--   GRANTs are needed for it. The role name is not hard-coded — the owner is
--   whoever runs Flyway (`current_user`).
--
-- Read-only access for other roles lives in R__roles.sql (`pdl_etl_reader`).
-- Flyway executes R__ migrations alphabetically by description, so
-- `permissions` runs BEFORE `roles`; role-specific grants are co-located
-- with the role's CREATE in R__roles.sql to avoid ordering issues.
--
-- Adding a new schema:
--   1. Append the schema name to _managed_schemas below and to the schema
--      list in R__roles.sql.
--   2. Add it to flyway.schemas in flyway.conf and the -schemas flag used by
--      docker-compose's flyway-init service.
-- =============================================================================

DO $$
DECLARE
  _managed_schemas text[] := ARRAY['catalog', 'raw', 'pdl_api', 'ref', 'integration', 'staging'];
  s text;
BEGIN
  -- Managed schemas — confirm ownership by the migrating role. Idempotent:
  -- schemas Flyway auto-creates from flyway.schemas are already owned by it.
  -- Re-asserting protects against schemas created out-of-band.
  FOREACH s IN ARRAY _managed_schemas LOOP
    IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = s) THEN
      EXECUTE format('ALTER SCHEMA %I OWNER TO %I', s, current_user);
    END IF;
  END LOOP;
END $$;
