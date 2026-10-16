{#-
  recreate_fks: read FK definitions from catalog._dropped_fks and recreate
  each constraint WITH NOT VALID. Truncate the tracking table on success.

  Per ADR-0009 (Pattern 2 FK drop/recreate for stateless rebuild).
  Called from on-run-end in dbt_project.yml.

  Why NOT VALID: integration + ref are rebuilt every cycle; there are no
  live INSERTs into integration between rebuilds, so Postgres-level
  per-INSERT FK enforcement protects against nothing. The actual orphan-row
  check happens via dbt's `relationships` tests in schema.yml at `dbt build`
  time. NOT VALID skips the row-by-row validation scan (huge speedup on
  millions of rows) while keeping the constraint registered in pg_catalog
  for documentation value (\d output, ER-diagram tools). New inserts after
  this point ARE still checked against the FK (constraint applies to new
  data); only existing rows are unverified.

  Behavior:
    1. Iterate catalog._dropped_fks rows.
    2. For each: ALTER TABLE ADD CONSTRAINT <conname> <constraint_def> NOT VALID
       where constraint_def came from pg_get_constraintdef() at drop time —
       i.e., 'FOREIGN KEY (col) REFERENCES other_table(col) ON DELETE ...'.
    3. TRUNCATE the tracking table on success.
    4. Emit a NOTICE with the recreate count for log visibility.

  Important: on-run-end runs even if `dbt build` had model or test failures
  upstream. This is intentional — ensures FK constraints get re-added even
  on partial-failure runs.

  Side effects: pg_catalog changes (ADD CONSTRAINT). No data changes.

  Failure case: if an individual ADD CONSTRAINT fails (extremely rare —
  the constraint_def was captured intact via pg_get_constraintdef), the DO
  block raises. Tracking table is NOT truncated, so the next run's drop_fks
  sees rows + skips capture, and recreate_fks retries all FKs. Retryable
  without operator action.
-#}

{% macro recreate_fks() %}
  {% set sql %}
    DO $$
    DECLARE
      recreated_now int := 0;
      rec           record;
    BEGIN
      FOR rec IN
        SELECT conname, table_name, constraint_def
        FROM   catalog._dropped_fks
      LOOP
        -- pg_get_constraintdef returns the constraint body without the
        -- leading 'ALTER TABLE ... ADD CONSTRAINT name', e.g.:
        --   'FOREIGN KEY (col) REFERENCES other(col) ON DELETE NO ACTION'
        -- We compose the full ALTER TABLE ADD CONSTRAINT statement +
        -- append NOT VALID to skip retroactive validation.
        EXECUTE format(
          'ALTER TABLE %s ADD CONSTRAINT %I %s NOT VALID',
          rec.table_name, rec.conname, rec.constraint_def
        );
        recreated_now := recreated_now + 1;
      END LOOP;

      TRUNCATE catalog._dropped_fks;

      RAISE NOTICE 'recreate_fks: recreated % FK(s) with NOT VALID; tracking table cleared',
                   recreated_now;
    END $$;
  {% endset %}
  {% if execute %}
    {% do run_query(sql) %}
  {% endif %}
{% endmacro %}
