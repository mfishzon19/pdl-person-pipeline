{#-
  ref.metro — DISTINCT (country, metro) tuples from PDL address data.

  country_id NOT NULL (INNER JOIN to ref.country). msa_code stays
  NULL — advisory US Census MSA code, owned by a future seed migration.
  display_name was dropped in V12.

  UNIQUE on (country_id, name_lc) per ref.dbml (V4__ref_baseline.sql).

  LOWER() defensively on the join key + the inserted name_lc.

  Surrogate id + timestamps: dbt-computed in the SELECT (V14 dropped
  the IDENTITY clause from `id`). See ADR-0008.

  Source-of-truth shape: modeling/dbml/ref.dbml block `ref.metro`.
  DDL in V4__ref_baseline.sql + V14__ref_drop_identity_from_id.sql.
-#}

WITH distinct_metros AS (
  SELECT DISTINCT
    c.id           AS country_id,
    LOWER(a.metro) AS name_lc
  FROM {{ ref('pdl_person_addresses_unique') }} a
  JOIN {{ ref('country') }} c
    ON c.name_lc = LOWER(a.country)
  WHERE a.metro IS NOT NULL AND a.metro <> ''
)

SELECT
  ROW_NUMBER() OVER (ORDER BY country_id, name_lc) AS id,
  country_id,
  name_lc,
  NULL::text                                       AS msa_code,
  now()                                            AS timestamp_created,
  now()                                            AS timestamp_modified
FROM distinct_metros
