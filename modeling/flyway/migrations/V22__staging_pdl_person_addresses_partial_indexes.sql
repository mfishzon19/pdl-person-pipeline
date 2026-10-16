-- =============================================================================
-- V22 — Partial indexes on staging.pdl_person_addresses_unique for the two
--       source_context values that integration.* models filter on.
--
-- WHY:
-- staging.pdl_person_addresses_unique is the UNION of three address paths
-- inside a PDL person payload (docs/design/15 §3), distinguished by source_context:
--   - 'person_home'             (at most one row per person)
--   - 'experience_company_hq'   (one row per experience entry; the largest)
--   - 'education_school'        (one row per education entry)
--
-- Integration models filter to ONE source_context per consumer:
--   - integration.person                   → WHERE source_context = 'person_home' AND source_idx = 0
--   - integration.company_hq_address (V21) → WHERE source_context = 'experience_company_hq'
--   - integration.school (potential)       → WHERE source_context = 'education_school'
--
-- The existing indexes lead on person_pdl_id, so source_context filters
-- force a sequential scan + filter over the whole table. On a full delivery
-- the integration.company_hq_address INSERT was still running after many
-- minutes before being killed in favor of these indexes.
--
-- Two partial indexes here (one per source_context value with
-- actual or near-term consumer):
--   1. person_home (also pins source_idx=0 since the home address is always
--      the singleton top-level person.location_* path; saves a tiny lookup)
--   2. experience_company_hq (source_idx is the experience-array index;
--      not pinned)
--
-- education_school is intentionally NOT indexed yet: integration.school was
-- not authored when this migration landed, and PDL's school location is coarse-grain only (just
-- country/locality), so the future model likely uses ref.location chain
-- directly without needing this access pattern. Add when measured pain.
--
-- WHY PARTIAL (not composite (source_context, person_pdl_id, source_idx)):
--   - Smaller per-query index footprint (only the matching source_context's
--     rows instead of the whole table)
--   - Better cache locality for the specific filter
--   - Index entries are only modified during the rebuild for matching
--     source_context — lower write cost during _unique INSERT
--   - source_context values are fixed by docs/design/15 design (3 hardcoded paths);
--     no growth in cardinality means no future "what if more source_contexts"
--     concern that would favor composite.
--
-- DBML caveat — same precedent as V5 ref.location COALESCE index and V19
-- staging dedup functional index: DBML cannot express `WHERE` predicates in
-- Indexes blocks. The 2 indexes are documented in staging.dbml as table-
-- level Notes; this migration is the canonical DDL.
--
-- Pattern 1 — the existing dbt_project.yml hooks for pdl_person_addresses_
-- unique drop the secondary index + UNIQUE constraint pre-INSERT and
-- recreate post-INSERT. This migration adds two more indexes to that
-- drop/recreate set; dbt_project.yml is updated alongside this migration.
-- =============================================================================

CREATE INDEX idx_pdl_person_addresses_unique_person_home
  ON staging.pdl_person_addresses_unique (person_pdl_id)
  WHERE source_context = 'person_home' AND source_idx = 0;

CREATE INDEX idx_pdl_person_addresses_unique_company_hq
  ON staging.pdl_person_addresses_unique (person_pdl_id, source_idx)
  WHERE source_context = 'experience_company_hq';

COMMENT ON INDEX staging.idx_pdl_person_addresses_unique_person_home IS
  'Partial index supporting integration.person home-address lookups. WHERE source_context = ''person_home'' AND source_idx = 0. One entry per person who has a home address. DBML cannot express partial-index predicates — see V5/V19 precedent.';

COMMENT ON INDEX staging.idx_pdl_person_addresses_unique_company_hq IS
  'Partial index supporting integration.company_hq_address builds. WHERE source_context = ''experience_company_hq''. One entry per person × experience entry with company HQ data. Used to JOIN through pdl_person_experience_unique for company_pdl_id resolution. DBML cannot express partial-index predicates.';
