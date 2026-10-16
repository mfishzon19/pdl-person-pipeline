{#-
  ref.country — DISTINCT country vocabulary from PDL address data.

  continent_id resolved via LEFT JOIN to ref.continent (NULL when the
  source row had no continent). This populates continent_id from PDL
  data, overriding the DBML's conservative "future seed" note —
  PDL emits continent on most address rows, so we use it.

  iso_alpha_2 / iso_alpha_3 stay NULL — advisory columns owned by a
  future seed migration. display_name was dropped in V12.

  LOWER() defensively on both the SELECT and the JOIN key per
  ref.dbml's name_lc convention.

  Surrogate id + timestamps: dbt-computed in the SELECT (V14 dropped
  the IDENTITY clause from `id`). See ADR-0008.

  Source-of-truth shape: modeling/dbml/ref.dbml block `ref.country`.
  DDL in V4__ref_baseline.sql + V14__ref_drop_identity_from_id.sql.
-#}

-- DISTINCT ON (name_lc) collapses the case where PDL emits the same
-- country WITH and WITHOUT a continent across different source rows
-- (e.g. 'united kingdom' shows up paired with 'europe' on most rows but
-- with NULL on a few). A plain DISTINCT would keep both tuples and
-- break the UNIQUE on (name_lc). The ORDER BY ... NULLS LAST keeps the
-- row whose continent_id resolved.
WITH distinct_countries AS (
  SELECT DISTINCT ON (LOWER(a.country))
    LOWER(a.country) AS name_lc,
    c.id             AS continent_id
  FROM {{ ref('pdl_person_addresses_unique') }} a
  LEFT JOIN {{ ref('continent') }} c
    ON c.name_lc = LOWER(a.continent)
  WHERE a.country IS NOT NULL AND a.country <> ''
  ORDER BY LOWER(a.country), c.id NULLS LAST
)

SELECT
  ROW_NUMBER() OVER (ORDER BY name_lc) AS id,
  name_lc,
  continent_id,
  NULL::text                           AS iso_alpha_2,
  NULL::text                           AS iso_alpha_3,
  now()                                AS timestamp_created,
  now()                                AS timestamp_modified
FROM distinct_countries
