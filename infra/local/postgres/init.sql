-- Local Postgres init script (runs once, on first container start).
--
-- Mounted into /docker-entrypoint-initdb.d/ via docker-compose. Postgres
-- runs every .sql file in that dir on the very first boot, after the
-- POSTGRES_USER + POSTGRES_DB env vars have created the role + database
-- but BEFORE Flyway runs.
--
-- Installs the extensions the schema needs. Role/auth setup is already
-- done by compose via POSTGRES_USER. Flyway's repeatable migrations
-- (R__roles.sql, R__permissions.sql) handle the rest once it runs.

-- Required by catalog.pipeline_run.pipeline_run_id DEFAULT gen_random_uuid().
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Useful for any analyst poking at JSON columns in pgAdmin.
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- No S3 extension is needed: the ingester (processing/s3_ingester/
-- file_ingester.py) downloads files via boto3 and streams them in with
-- COPY ... FROM STDIN.

-- Sanity print so `docker compose logs postgres` shows init ran.
DO $$ BEGIN
  RAISE NOTICE 'init.sql complete: pgcrypto + pg_trgm installed, ready for Flyway';
END $$;
