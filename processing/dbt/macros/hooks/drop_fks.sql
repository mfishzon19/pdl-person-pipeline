{#-
  drop_fks: capture + drop all FK constraints in the specified schemas before
  a dbt rebuild starts. Stores definitions in catalog._dropped_fks so that
  recreate_fks (on-run-end) can replay them.

  Per ADR-0009 (Pattern 2 FK drop/recreate for stateless rebuild).
  Called from on-run-start in dbt_project.yml.

  Idempotent: if the tracking table already has rows from a previous aborted
  run, this macro skips the capture step and lets recreate_fks handle the
  leftovers on this run's on-run-end. Self-healing recovery; no operator
  intervention needed.

  Usage:
    {{ drop_fks(['ref', 'integration']) }}

  Behavior:
    1. Check catalog._dropped_fks; if non-empty, NOTICE + RETURN (recovery path).
    2. Otherwise: query pg_constraint for all FKs in the target schemas,
       INSERT each (conname, table_name, constraint_def) into catalog._dropped_fks,
       then ALTER TABLE ... DROP CONSTRAINT for each.
    3. Emit a NOTICE with the drop count for log visibility.

  NOTICE output appears in the `dbt run` log so the constraint count is
  visible at a glance; it should match the number of FKs the DBML declares
  across ref + integration.

  Side effects: pg_catalog changes (DROP CONSTRAINT). No data changes.
-#}

{% macro drop_fks(schemas) %}
  {% set schemas_csv = "'" ~ schemas|join("','") ~ "'" %}
  {% set sql %}
    DO $$
    DECLARE
      already_dropped int;
      dropped_now     int := 0;
      rec             record;
    BEGIN
      -- Recovery path: if a previous run aborted between drop and recreate,
      -- the tracking table still has rows. Skip the capture; let
      -- recreate_fks (on-run-end this run) handle those leftovers.
      SELECT count(*) INTO already_dropped FROM catalog._dropped_fks;
      IF already_dropped > 0 THEN
        RAISE NOTICE 'drop_fks: % FK(s) already in tracking table (prior aborted run); skipping capture',
                     already_dropped;
        RETURN;
      END IF;

      -- Capture every FK constraint in the configured schemas, then drop it.
      FOR rec IN
        SELECT con.conname                              AS conname,
               (ns.nspname || '.' || tbl.relname)::text AS tname,
               pg_get_constraintdef(con.oid)::text      AS cdef
        FROM   pg_constraint con
        JOIN   pg_class tbl       ON tbl.oid       = con.conrelid
        JOIN   pg_namespace ns    ON ns.oid        = tbl.relnamespace
        WHERE  con.contype = 'f'
          AND  ns.nspname IN ({{ schemas_csv }})
      LOOP
        INSERT INTO catalog._dropped_fks (conname, table_name, constraint_def)
        VALUES (rec.conname, rec.tname, rec.cdef);

        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',
                       rec.tname, rec.conname);
        dropped_now := dropped_now + 1;
      END LOOP;

      RAISE NOTICE 'drop_fks: dropped % FK(s) (from configured schemas)',
                   dropped_now;
    END $$;
  {% endset %}
  {% if execute %}
    {% do run_query(sql) %}
  {% endif %}
{% endmacro %}
