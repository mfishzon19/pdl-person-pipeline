{#-
  integration.company_affiliation — company hierarchy + parent/subsidiary
  junction (docs/data_model/08 §4.2, docs/design/18_pdl_api_generic_caller.md).

  One row per staging.pdl_api_company_parsed.affiliated_entities[] element
  {affiliated_id, display_name, relationship}. Sole source — PDL's sibling
  denormalizations (affiliated_profiles, direct_subsidiaries,
  all_subsidiaries) carry the same id set and are dropped (docs/data_model/08 §5.2).

  All three JOINs are INNER and always resolve — no orphan drops:
    - c1 (subject)    : every enriched company is in integration.company.
    - c2 (affiliated) : every affiliated_id is in integration.company via
                        the stub-insert pattern (docs/data_model/08 §6.4).
    - r  (relationship): every relationship value is in ref.pdl_relationship
                        (loader-discovered from this same source).
  Conservation invariant: junction row count equals the number of distinct
  (subject, affiliated_id, relationship) elements across staging
  affiliated_entities[] (see the DISTINCT ON note below).

  status_id / catalyst_id: reserved nullable for the future Parent
  Subsidiary Details extension — PDL doesn't emit status/catalyst on our
  current contract and the ref tables don't exist yet (docs/data_model/08 §4.4,
  ADR-0011). NULL::bigint.

  display_name is NOT stored here — it already lives on integration.company.
  name (set by the stub-insert for otherwise-unknown affiliated companies).

  Source-of-truth shape: modeling/dbml/integration.dbml block
  `integration.company_affiliation`. DDL in V28. on_schema_change='fail'
  enforces this SELECT matches the table.
-#}

-- DISTINCT ON the composite PK: PDL occasionally emits duplicate
-- affiliated_entities[] elements within a single company, which would
-- violate the (subject, affiliated, relationship) PK from V28/DBML. The
-- junction is keyed on those 3 columns by contract, so duplicate edges
-- collapse to one row. dataset_version tie-break is deterministic (dups are
-- content-identical). Conservation therefore counts distinct elements, not
-- the raw element count.
SELECT DISTINCT ON (c1.id, c2.id, r.id)
  c1.id            AS subject_company_id,
  c2.id            AS affiliated_company_id,
  r.id             AS relationship_id,
  NULL::bigint     AS status_id,
  NULL::bigint     AS catalyst_id,
  src.dataset_version,
  now()            AS timestamp_created,
  now()            AS timestamp_modified
-- CROSS JOIN LATERAL (not the comma form in docs/design/18_pdl_api_generic_caller.md) so src stays in
-- scope for the ON clauses of the explicit JOINs below — Postgres won't
-- resolve a comma-list alias across an explicit JOIN boundary.
FROM {{ ref('pdl_api_company_parsed') }} src
CROSS JOIN LATERAL jsonb_array_elements(src.affiliated_entities) AS e(elem)
JOIN {{ ref('company') }}          c1 ON c1.pdl_company_id = src.pdl_company_id
JOIN {{ ref('company') }}          c2 ON c2.pdl_company_id = (e.elem->>'affiliated_id')
JOIN {{ ref('pdl_relationship') }} r  ON r.relationship    = (e.elem->>'relationship')
-- Explicit blank guards for parity with ref/pdl_relationship.sql and
-- company.sql's affiliated_flat. The INNER JOINs already drop blanks, but
-- keeping the filter explicit makes the contract consistent across the models.
WHERE e.elem->>'affiliated_id' IS NOT NULL
  AND e.elem->>'affiliated_id' <> ''
  AND e.elem->>'relationship'  IS NOT NULL
  AND e.elem->>'relationship'  <> ''
ORDER BY c1.id, c2.id, r.id, src.dataset_version
