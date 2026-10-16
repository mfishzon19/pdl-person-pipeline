{#-
  generate_schema_name — bare schema name override.

  Without this macro, dbt resolves +schema: staging to "<target>_staging"
  by concatenating the profile's target schema (e.g. "dev") with the
  config's schema. Our schemas are Flyway-managed and have bare names
  (staging, integration, ref), so we need to ignore the target schema
  when a custom one is specified.

  Behavior:
    - If a model declares +schema: X, write to X (bare).
    - If no custom schema is declared, fall back to target.schema (the
      profile default, `dev_local` unless DBT_PG_SCHEMA overrides it).

  Required for Flyway/dbt ownership contract (docs/design/02 §11): dbt models
  write into pre-existing Flyway-created tables in staging / integration
  / ref. Without this override, dbt looks for dev_integration.person
  instead of integration.person and silently materializes a new table in
  the wrong place.
-#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
