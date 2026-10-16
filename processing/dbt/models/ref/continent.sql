{#-
  ref.continent — DISTINCT continent vocabulary from PDL address data.

  One row per distinct continent string observed across all three
  source contexts in pdl_person_addresses_unique (person_home,
  experience_company_hq, education_school). Source-context-agnostic —
  for ref-vocab purposes we just want the DISTINCT set (a handful of
  rows — PDL emits the standard continent names).

  LOWER() defensively: name_lc holds lowercased English per ref.dbml.
  PDL emits lowercase by convention but LOWER() is cheap insurance.

  display_name was dropped from this table in V12 (no canonical
  third-party source for it).

  Surrogate id + timestamps: dbt-computed in the SELECT. V4 originally
  created `id` as GENERATED ALWAYS AS IDENTITY; V14 dropped the IDENTITY
  so dbt can supply values explicitly via ROW_NUMBER. Project-wide
  on_schema_change='fail' applies — no per-model override needed. See
  ADR-0008.

  Source-of-truth shape: modeling/dbml/ref.dbml block `ref.continent`.
  DDL in V4__ref_baseline.sql + V14__ref_drop_identity_from_id.sql.
-#}

WITH distinct_continents AS (
  SELECT DISTINCT
    LOWER(continent) AS name_lc
  FROM {{ ref('pdl_person_addresses_unique') }}
  WHERE continent IS NOT NULL AND continent <> ''
)

SELECT
  ROW_NUMBER() OVER (ORDER BY name_lc) AS id,
  name_lc,
  now()                                AS timestamp_created,
  now()                                AS timestamp_modified
FROM distinct_continents
