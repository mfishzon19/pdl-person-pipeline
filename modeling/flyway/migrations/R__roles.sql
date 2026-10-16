-- =============================================================================
-- R__roles.sql — optional read-only role for the local PDL database.
--
-- HAND-AUTHORED. Repeatable migration: Flyway re-runs whenever this file's
-- checksum changes. Idempotent — CREATE ROLE is wrapped in an IF NOT EXISTS
-- check and every GRANT is additive.
--
-- Roles:
--   <owner>     The login role Flyway connects as (`pdl_etl` in docker-compose).
--               Owns all schemas/objects; see R__permissions.sql.
--   pdl_etl_reader  NOLOGIN bundle with read-only access (USAGE + SELECT) on
--               every data schema. Grant it to any ad-hoc LOGIN role that
--               should be able to query but not modify data:
--
--                 CREATE ROLE analyst LOGIN PASSWORD '...';  -- run by hand
--                 GRANT pdl_etl_reader TO analyst;
--
-- Passwords are never set in migration files (they would be stored in
-- flyway_schema_history and version control).
--
-- Removing a role: deleting a block here does NOT drop the role — write a
-- versioned migration with DROP ROLE instead.
-- =============================================================================

DO $$
DECLARE
  _data_schemas text[] := ARRAY['catalog', 'raw', 'pdl_api', 'ref', 'integration', 'staging'];
  s text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pdl_etl_reader') THEN
    CREATE ROLE pdl_etl_reader
      NOLOGIN
      NOSUPERUSER
      INHERIT
      NOCREATEDB
      NOCREATEROLE
      NOREPLICATION
      NOBYPASSRLS;
  END IF;

  EXECUTE format('GRANT CONNECT ON DATABASE %I TO pdl_etl_reader', current_database());

  -- Per-schema grants. The migrating role owns each schema and its tables,
  -- so ALTER DEFAULT PRIVILEGES FOR ROLE <owner> covers future tables too
  -- (including those dbt and the ingester create on later runs).
  FOREACH s IN ARRAY _data_schemas LOOP
    IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = s) THEN
      EXECUTE format('GRANT USAGE ON SCHEMA %I TO pdl_etl_reader', s);
      EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO pdl_etl_reader', s);
      EXECUTE format(
        'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT ON TABLES TO pdl_etl_reader',
        current_user, s);
    END IF;
  END LOOP;
END $$;
