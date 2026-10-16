-- =============================================================================
-- V27 — carry experience_idx through integration.experience to enable fast
--       integer JOINs from per-experience junction models.
--
-- PROBLEM:
--   integration.experience_location / _industry / _seniority_level all
--   need to map per-experience source rows (keyed by (person_pdl_id,
--   experience_idx) at staging) back to their integration.experience.id.
--   Initial design used a 4-column natural-key JOIN on (person_id,
--   company_id, start_year, title) with the COALESCE pattern to handle
--   nullable columns. Measured on a full delivery:
--     - experience_industry: well over ten minutes (succeeded but slow)
--     - experience_location: connection dropped after more than half an
--       hour (failed)
--     - experience_seniority_level: well over ten minutes (succeeded but slow)
--   No expression index can be added on integration.experience to make the
--   COALESCE-wrapped 4-col join planner-usable (V5's COALESCE indexes on
--   ref.* are precedent but the convention doesn't extend cleanly to
--   integration.experience's mostly-non-null columns + free-text title).
--
-- FIX:
--   Carry the source experience_idx column through to integration.experience.
--   experience_idx is the PDL array position within $.experience[*] and is
--   already on staging.pdl_person_experience_unique. (person_id,
--   experience_idx) is unique per integration.experience row by construction.
--   Junction models can then JOIN by (person_id, experience_idx) — two
--   integer cols, index-friendly. ~10x faster expected vs the COALESCE
--   natural-key JOIN.
--
-- BLAST RADIUS:
--   - ADD COLUMN nullable, default NULL. Instant.
--   - Existing integration.experience rows get NULL until the dbt model
--     rebuilds (stateless rebuild — TRUNCATE pre_hook + repopulate).
--   - Pattern 1 hooks for integration.experience gain a new index on
--     (person_id, experience_idx); index creation is post_hook on the
--     freshly populated table.
--   - integration.experience.sql adds experience_idx to its SELECT,
--     sourced from pdl_person_experience_unique.experience_idx.
--   - DBML (integration.dbml) updated in the same change.
-- =============================================================================

ALTER TABLE integration.experience
  ADD COLUMN experience_idx int4;

COMMENT ON COLUMN integration.experience.experience_idx IS
  'PDL array position within $.experience[*] for the source row, carried through staging.pdl_person_experience_unique.experience_idx. Combined with person_id, uniquely identifies each integration.experience row. Used as the JOIN key from per-experience junction models (experience_location, experience_industry, experience_seniority_level) to avoid the slow 4-col natural-key COALESCE join. See V27 header.';
