-- =============================================================================
-- V19 — Staging dedup covering indexes
--
-- Add covering indexes on 5 staging _parsed tables that source the DISTINCT ON
-- queries in their corresponding _unique dbt models. Without these, the
-- _unique builds do an Incremental Sort over millions of rows per build —
-- the companies_unique case ran for hours and timed out under the previous
-- planner choices. With a matching covering index, Postgres uses Index Only
-- Scan to stream pre-sorted rows and the sort step disappears entirely.
--
-- Measured on a full delivery: the companies_unique DISTINCT ON went from a
-- multi-hour timeout to about a minute (two orders of magnitude faster).
-- The same pattern applies to the other 4 large _unique models.
--
-- Each index's column order mirrors the (DISTINCT ON + ORDER BY) clause of
-- its consumer _unique model:
--   _unique model                              ORDER BY
--   ─────────────────────────────────────────  ──────────────────────────────
--   pdl_person_experience_unique               person_pdl_id, company_pdl_id,
--                                              start_year, title_name,
--                                              loaded_at DESC, partition_id DESC
--   pdl_person_education_unique                person_pdl_id, school_pdl_id,
--                                              start_year, degrees::text,
--                                              loaded_at DESC, partition_id DESC
--   pdl_person_companies_unique                company_pdl_id, loaded_at DESC,
--                                              partition_id DESC
--   pdl_person_schools_unique                  school_pdl_id, loaded_at DESC,
--                                              partition_id DESC
--   pdl_person_addresses_unique                person_pdl_id, source_context,
--                                              source_idx, loaded_at DESC,
--                                              partition_id DESC
--
-- pdl_person_unique is NOT in this list: its DISTINCT ON key is
-- `resolved_pdl_id`, a COALESCE over LEFT JOINs to alias-resolution CTEs.
-- A covering index on `pdl_person_parsed(pdl_id, ...)` wouldn't help that
-- sort. And pdl_person_unique already runs in minutes on a full delivery —
-- not slow enough to need this optimization.
--
-- Index management: dbt pre/post hooks on each _parsed model drop these
-- indexes before the bulk INSERT and recreate after, matching the existing
-- Pattern 1 convention for secondary indexes. See processing/dbt/dbt_project.yml.
--
-- IF NOT EXISTS makes each statement a no-op on a database where an index
-- of the same name was already built by hand (e.g. CONCURRENTLY during a
-- performance investigation).
--
-- Cross-references:
--   - docs/decisions/0003-staging-bulk-load-pattern-1.md (existing Pattern 1)
--   - modeling/dbml/staging.dbml (table-level Note on each table covers
--     the exact DESC ordering DBML can't express in its Indexes block)
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_pdl_person_experience_parsed_dedup
  ON staging.pdl_person_experience_parsed
  (person_pdl_id, company_pdl_id, start_year, title_name, loaded_at DESC, partition_id DESC);

CREATE INDEX IF NOT EXISTS idx_pdl_person_education_parsed_dedup
  ON staging.pdl_person_education_parsed
  (person_pdl_id, school_pdl_id, start_year, (degrees::text), loaded_at DESC, partition_id DESC);

CREATE INDEX IF NOT EXISTS idx_pdl_person_companies_parsed_dedup
  ON staging.pdl_person_companies_parsed
  (company_pdl_id, loaded_at DESC, partition_id DESC);

CREATE INDEX IF NOT EXISTS idx_pdl_person_schools_parsed_dedup
  ON staging.pdl_person_schools_parsed
  (school_pdl_id, loaded_at DESC, partition_id DESC);

CREATE INDEX IF NOT EXISTS idx_pdl_person_addresses_parsed_dedup
  ON staging.pdl_person_addresses_parsed
  (person_pdl_id, source_context, source_idx, loaded_at DESC, partition_id DESC);
