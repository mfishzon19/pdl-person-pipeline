-- =============================================================================
-- V16 — Integration schema cleanup pass
--
-- Bundled cleanup covering several open items (PDL bool-placeholder fields,
-- empty name_aliases, and related staging/integration dead columns) plus
-- the decisions of an integration-design review.
-- All affected tables are EMPTY (PDL certifications / languages /
-- name_aliases are never delivered in the PDL field bundle this pipeline
-- receives; mobile_phone etc. are bool-placeholders). DROP / DROP COLUMN /
-- DROP-and-CREATE are safe with no data preservation needed.
--
-- Scope:
--
--   Drop unsourced integration junction tables (no PDL source):
--     - integration.person_social_network    (PDL contributes LinkedIn-only,
--                                             already on integration.person scalars)
--     - integration.person_name_alias        (never populated in a full delivery)
--     - integration.person_certification     (V10 dropped staging; no source)
--
--   integration.person column changes (verified against a full delivery):
--     DROP — never populated; keys absent from the PDL JSON this pipeline receives:
--       linkedin_connections, inferred_years_experience, first_seen,
--       num_sources, num_records
--     DROP — PDL bool-placeholder:
--       mobile_phone
--     DROP — degenerate at row grain (one distinct value per delivery;
--     belongs in catalog.pdl_person_provenance, future work):
--       dataset_version
--     ADD — real per-record PDL freshness signals (populated for most
--     persons; required for identity-resolution and job-history-recency
--     logic):
--       job_last_changed, job_last_verified, location_last_updated
--
--   integration.company industry refactor:
--     DROP industry text, industry_v2 text
--     ADD industry_id bigint FK to ref.industry, industry_v2_id bigint FK to
--         ref.industry_v2. Consistent with integration.person.industry_id.
--     Indexes on the new FK columns.
--
--   integration.experience_industry — add per-edge source col (provenance of
--   the edge; matches existing ref.industry.source_type pattern at the dim
--   level).
--
--   staging bool-placeholder drops:
--     staging.pdl_person_parsed and staging.pdl_person_unique — drop the
--     8-9 confirmed-junk columns from each, plus name_aliases.
--     Columns absent from staging entirely (birth_year, birth_date,
--     recommended_personal_email, street_addresses) need no DROP — they
--     were never parsed into columns; they are listed here only to prevent
--     future schema-add proposals.
--
-- Cross-references:
--   - docs/data_model/13_person.md §4.12
--   - modeling/dbml/integration.dbml + ref.dbml + staging.dbml (DBML diff)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Step 1. Drop unsourced integration junction tables.
-- All three have only outbound FKs (to integration.person); no other tables
-- reference them, so plain DROP TABLE is safe.
-- -----------------------------------------------------------------------------
DROP TABLE integration.person_social_network;
DROP TABLE integration.person_name_alias;
DROP TABLE integration.person_certification;

-- -----------------------------------------------------------------------------
-- Step 2. Drop dead columns from integration.person.
-- linkedin_connections / inferred_years_experience / first_seen / num_sources /
-- num_records: never populated (JSON keys absent from the PDL payload this
-- pipeline receives).
-- mobile_phone: confirmed bool-placeholder (only 'false'/'true' literals).
-- dataset_version: always populated but a single value per delivery —
-- degenerate at row grain. Belongs in catalog.pdl_person_provenance (future work).
-- -----------------------------------------------------------------------------
ALTER TABLE integration.person
  DROP COLUMN mobile_phone,
  DROP COLUMN linkedin_connections,
  DROP COLUMN inferred_years_experience,
  DROP COLUMN dataset_version,
  DROP COLUMN first_seen,
  DROP COLUMN num_sources,
  DROP COLUMN num_records;

-- -----------------------------------------------------------------------------
-- Step 3. Add real PDL freshness signals.
-- The freshness signals are populated for most but not all persons; the
-- gaps require an explicit NULL-handling strategy when identity-resolution
-- + job-history logic is built (see docs/data_model/14_sources.md §2).
-- -----------------------------------------------------------------------------
ALTER TABLE integration.person
  ADD COLUMN job_last_changed      timestamptz,
  ADD COLUMN job_last_verified     timestamptz,
  ADD COLUMN location_last_updated timestamptz;

-- -----------------------------------------------------------------------------
-- Step 4. Refactor integration.company.industry / industry_v2 from text to FK,
-- for consistency with integration.person.industry_id,
-- which is already an FK to ref.industry.
-- -----------------------------------------------------------------------------
ALTER TABLE integration.company
  DROP COLUMN industry,
  DROP COLUMN industry_v2,
  ADD COLUMN industry_id    bigint REFERENCES ref.industry(id),
  ADD COLUMN industry_v2_id bigint REFERENCES ref.industry_v2(id);
CREATE INDEX idx_company_industry_id    ON integration.company(industry_id);
CREATE INDEX idx_company_industry_v2_id ON integration.company(industry_v2_id);

-- -----------------------------------------------------------------------------
-- Step 5. Add per-edge source column to integration.experience_industry.
-- ref.industry.source_type tracks where each NAME first appeared; this
-- column tracks which source attested THIS edge ('pdl'). Table is EMPTY at
-- this point, so NOT NULL with no DEFAULT is fine.
-- -----------------------------------------------------------------------------
ALTER TABLE integration.experience_industry
  ADD COLUMN source text NOT NULL;

-- -----------------------------------------------------------------------------
-- Step 6. Drop bool-placeholder columns from staging.
-- Confirmed bool-placeholders (verified on a sample: only 'false'/'true'
-- literals, no real values).
-- name_aliases: never populated in a full delivery.
--
-- Bool-placeholder fields that are NOT in this list:
--   - birth_year, birth_date, recommended_personal_email, street_addresses
--     (plural) — bool-placeholders but never parsed into staging
--     columns; no DROP migration needed.
--   - location_street_address, location_address_line_2 on pdl_person_unique —
--     already dropped from pdl_person_unique in V12 (still on pdl_person_parsed
--     until this migration).
--   - facebook_friends — always-NULL companion of facebook_url, but not
--     itself a bool-placeholder; retained for now.
-- -----------------------------------------------------------------------------
ALTER TABLE staging.pdl_person_parsed
  DROP COLUMN github_url,
  DROP COLUMN github_username,
  DROP COLUMN twitter_url,
  DROP COLUMN twitter_username,
  DROP COLUMN facebook_url,
  DROP COLUMN facebook_id,
  DROP COLUMN facebook_username,
  DROP COLUMN mobile_phone,
  DROP COLUMN location_street_address,
  DROP COLUMN location_address_line_2,
  DROP COLUMN name_aliases;

ALTER TABLE staging.pdl_person_unique
  DROP COLUMN github_url,
  DROP COLUMN github_username,
  DROP COLUMN twitter_url,
  DROP COLUMN twitter_username,
  DROP COLUMN facebook_url,
  DROP COLUMN facebook_id,
  DROP COLUMN facebook_username,
  DROP COLUMN mobile_phone,
  DROP COLUMN name_aliases;
