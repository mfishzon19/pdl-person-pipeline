{#-
  ref.pdl_relationship — PDL company relationship-type vocabulary.

  Loader-discovered (ADR-0011): one row per distinct relationship value
  observed in staging.pdl_api_company_parsed.affiliated_entities[].relationship.
  No seed — the 4 current values (direct_subsidiary, indirect_subsidiary,
  immediate_parent, ultimate_parent) are learned from the data and any new
  PDL value is picked up automatically on the next rebuild. UNIQUE on
  relationship per ref.dbml.

  Surrogate id + timestamps: dbt-computed in the SELECT (no IDENTITY on the
  Flyway table). See ADR-0008.

  Source-of-truth shape: modeling/dbml/ref.dbml block `ref.pdl_relationship`.
  DDL in V28__company_enrichment_schema.sql.
-#}

WITH distinct_relationships AS (
  SELECT DISTINCT
    e.elem->>'relationship' AS relationship
  FROM {{ ref('pdl_api_company_parsed') }} c,
       jsonb_array_elements(c.affiliated_entities) AS e(elem)
  WHERE e.elem->>'relationship' IS NOT NULL
    AND e.elem->>'relationship' <> ''
)

SELECT
  ROW_NUMBER() OVER (ORDER BY relationship) AS id,
  relationship,
  now()                                     AS timestamp_created,
  now()                                     AS timestamp_modified
FROM distinct_relationships
