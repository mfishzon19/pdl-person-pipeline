-- =============================================================================
-- V25 — integration.experience design pivot:
--       (1) drop unused is_primary btree index
--       (2) replace composite-FK job_title_classification with 3 individual
--           FKs (title_class_id, title_role_id, title_sub_role_id) — preserves
--           partial classifications PDL emits (a noticeable share of rows
--           have class+role but no sub_role)
--       (3) drop vestigial ref.job_title_classification (now zero referrers)
--       (4) switch start_date/end_date timestamptz → start_year/end_year int4
--           (year-only convention)
--
-- DESIGN PIVOT — Option E:
--
-- V6 baseline created integration.experience.job_title_classification_id
-- as a single composite-FK to ref.job_title_classification(org_class, role,
-- sub_role). The composite-dim was elegant in principle but loses data when
-- PDL emits partial tuples:
--
--   Profiling staging.pdl_person_experience_unique on a full delivery:
--     most rows: all three present (111)     → composite FK works
--     many rows: all three NULL (000)        → no classification, expected
--     a noticeable share: class+role, no
--     sub_role                               → composite FK NULL despite real data
--
-- ref.job_title_classification requires all 3 NOT NULL, so every partial
-- row loses a meaningful classification. The "1 FK per dimension" design (Option
-- E) treats class/role/sub_role as independent canonical enums (PDL docs
-- describe each as a canonical enum string) — each gets a FK to its existing
-- ref dim (ref.job_title_class / ref.job_title_role / ref.job_title_subrole),
-- nullable independently. Partials handled naturally; no COALESCE join needed.
--
-- ref.job_title_classification becomes vestigial — its only purpose was
-- gluing the 3 dimensions into a single FK target. With 3 individual FKs,
-- no consumer references it. Drop the table + the
-- processing/dbt/models/ref/job_title_classification.sql model (deleted in
-- the same change).
--
-- YEAR-ONLY:
--
-- start_date/end_date were timestamptz columns implying month/day precision,
-- but PDL emits experience.start_date / end_date with year-only semantics
-- (PDL year-only precision). Storing them as timestamptz forced an awkward
-- make_date(year, 1, 1) cast that misrepresented the precision. V25 switches
-- to int4 columns matching the source shape — same convention staging
-- already uses (pdl_person_experience_unique.start_year / end_year int4).
--
-- BLAST RADIUS:
--   - integration.experience is EMPTY (no dbt model has populated it yet —
--     that model is authored alongside V25). All column changes are instant.
--   - Only FK into ref.job_title_classification was experience_job_title_
--     classification_id_fkey, which V25 drops first. DROP TABLE is then safe.
--   - The new title_class_id / title_role_id / title_sub_role_id FKs follow
--     ADR-0009 drop/recreate semantics; on-run-start macro discovers them
--     in pg_constraint automatically. No special handling needed.
--   - dbt_project.yml Pattern 1 hooks for integration.experience are added
--     in the same change (V6 baseline never had them since there was no model).
--   - DBML (integration.dbml + ref.dbml) updated in the same change to reflect
--     the final shape.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Drop the bool-column index that wouldn't pay back (same Pattern as V23)
-- -----------------------------------------------------------------------------

DROP INDEX IF EXISTS integration.idx_experience_is_primary;

-- -----------------------------------------------------------------------------
-- 2. Option E — replace composite-FK with 3 individual FKs per dimension
-- -----------------------------------------------------------------------------

ALTER TABLE integration.experience DROP CONSTRAINT IF EXISTS experience_job_title_classification_id_fkey;
DROP INDEX  IF EXISTS integration.idx_experience_classification_id;
ALTER TABLE integration.experience DROP COLUMN IF EXISTS job_title_classification_id;

ALTER TABLE integration.experience ADD COLUMN title_class_id    bigint REFERENCES ref.job_title_class(id);
ALTER TABLE integration.experience ADD COLUMN title_role_id     bigint REFERENCES ref.job_title_role(id);
ALTER TABLE integration.experience ADD COLUMN title_sub_role_id bigint REFERENCES ref.job_title_subrole(id);

COMMENT ON COLUMN integration.experience.title_class_id IS
  'FK to ref.job_title_class. NULL when PDL emitted no class. Independent of role / sub_role FKs (Option E — supports partial classifications PDL emits).';
COMMENT ON COLUMN integration.experience.title_role_id IS
  'FK to ref.job_title_role. NULL when PDL emitted no role.';
COMMENT ON COLUMN integration.experience.title_sub_role_id IS
  'FK to ref.job_title_subrole. NULL when PDL emitted no sub_role (or no role — sub_role is the most-frequently-NULL classification dimension; a noticeable share of staging rows have class+role but no sub_role).';

-- -----------------------------------------------------------------------------
-- 3. Drop vestigial composite-dim table (no remaining FK referrers)
-- -----------------------------------------------------------------------------

DROP TABLE IF EXISTS ref.job_title_classification;

-- -----------------------------------------------------------------------------
-- 4. start_date/end_date timestamptz → start_year/end_year int4
-- -----------------------------------------------------------------------------

DROP INDEX  IF EXISTS integration.idx_experience_start_date;
ALTER TABLE integration.experience DROP COLUMN IF EXISTS start_date;
ALTER TABLE integration.experience DROP COLUMN IF EXISTS end_date;

ALTER TABLE integration.experience ADD COLUMN start_year int4;
ALTER TABLE integration.experience ADD COLUMN end_year   int4;

COMMENT ON COLUMN integration.experience.start_year IS
  'Year experience started (4-digit). PDL emits experience.start_date with year-only precision; staging carries int4 to match. NULL when PDL emitted no start_date.';
COMMENT ON COLUMN integration.experience.end_year IS
  'Year experience ended (4-digit). NULL means current position (is_primary may or may not be TRUE — PDL marks current role via is_primary, end_year IS NULL is a weaker signal).';
