{#-
  integration.person_language — Person × Language junction (PDL).

  NO SOURCE — empty stub.

  PDL does not deliver languages on the current subscription tier
  (see docs/data_model/13 §4.13). staging.pdl_person_unique
  has no `languages` column (deliberate: V10 dropped staging.
  pdl_person_languages_parsed because PDL emits nothing). The model
  drops PDL proficiency (1–5) per the DBML note; the design intent is
  that the table is empty until PDL flips on languages OR another
  source provides them.

  This stub exists so the dbt DAG is complete and the table gets
  TRUNCATEd each rebuild (pre_hook). When a real source arrives,
  rewrite the SELECT to unnest the new source array + join to
  ref.language by name.

  Source-of-truth shape: modeling/dbml/integration.dbml block
  `integration.person_language`. DDL in V6 + V26 (timestamp columns
  added).
-#}

SELECT
  CAST(NULL AS bigint)      AS person_id,
  CAST(NULL AS bigint)      AS language_id,
  CAST(NULL AS timestamptz) AS timestamp_created,
  CAST(NULL AS timestamptz) AS timestamp_modified
WHERE FALSE
