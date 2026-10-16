-- =============================================================================
-- V12__staging_new_parsed_and_unique_tables.sql
--
-- HAND-AUTHORED. Generated downstream from modeling/dbml/staging.dbml.
-- Regenerate via modeling/scaffolding/ DBML compiler when built; until
-- then, this file is hand-authored against the DBML spec. Any drift is
-- a manual review concern.
--
-- Creates 8 new staging tables per the staging design (see
-- docs/design/15_pdl_staging_design.md, "Decided" and "Resolved decisions"):
--
--   3 NEW PARSED tables (flatten new sub-objects from raw.pdl_person):
--     staging.pdl_person_companies_parsed   — $.experience[*].company
--     staging.pdl_person_schools_parsed     — $.education[*].school
--     staging.pdl_person_addresses_parsed   — UNION ALL of 3 source
--                                             paths (person_home,
--                                             experience_company_hq,
--                                             education_school).
--                                             job_company_hq dropped
--                                             as redundant with the
--                                             is_primary experience
--                                             entry. See docs/design/15
--                                             decision #3.
--
--   5 NEW UNIQUE tables (dedup of corresponding parsed):
--     staging.pdl_person_experience_unique  — UNIQUE on 4-col natural key
--                                             with title_name discriminator
--     staging.pdl_person_education_unique   — UNIQUE on 4-col natural key
--                                             with degrees_text generated
--                                             column discriminator
--     staging.pdl_person_companies_unique   — UNIQUE on company_pdl_id
--     staging.pdl_person_schools_unique     — UNIQUE on school_pdl_id
--     staging.pdl_person_addresses_unique   — UNIQUE on
--                                             (person_pdl_id,
--                                              source_context,
--                                              source_idx)
--
-- staging.pdl_person_unique is NOT touched — its DDL was created in V7
-- baseline. dbt model rewrite ships separately.
--
-- DECISION CONTEXT:
--   - Dedup ordering: uniform placeholder
--       ORDER BY loaded_at DESC, partition_id DESC across every _unique
--       table. Per-table tie-breakers tuned later if needed.
--   - Natural keys (4-column, with a discriminator column): see the DBML
--     comments on each _unique table for the exact key per table and
--     the reasoning.
--   - Address pattern (one parsed table, three UNION'd source contexts:
--     person_home, experience_company_hq, education_school):
--     per-row provenance preserved as natural key. job_company_hq
--     dropped as redundant with is_primary experience entry.
--   - _staged tier: skipped entirely for PDL. No
--     _staged tables created here. Integration dbt models will read
--     from _unique directly.
--   - PDL company aliases: none (the Person delivery's MERGED_RECORDS only
--     emits person-id pairs).
--     companies_unique dedups directly on company_pdl_id.
--   - Location columns: Option A (additive only). The 10 location
--     columns currently on pdl_person_parsed (person_home + job_company_hq),
--     pdl_person_experience_parsed (company_location_*), and
--     pdl_person_education_parsed (school_location_* coarse-grain) are
--     NOT dropped in this migration. They remain redundant with
--     pdl_person_addresses_parsed until the Option B cleanup (future
--     work).
--
-- Population: dbt models in processing/dbt/models/staging/pdl_person/
-- (the new _parsed and _unique tables) populate these via the existing
-- staging materialization pattern (incremental + append + pre_hook
-- TRUNCATE per dbt_project.yml). The dbt models are authored separately.
-- =============================================================================


-- =============================================================================
-- pdl_person_companies_parsed
-- =============================================================================

CREATE TABLE staging.pdl_person_companies_parsed (
    -- Ingester provenance
    partition_id                              smallint,
    loaded_at                                 timestamptz,

    -- Source-record link (back to experience entry that referenced this company)
    person_pdl_id                             text,
    experience_idx                            int4,

    -- Company sub-object scalars
    company_pdl_id                            text,
    company_name                              text,
    company_size                              text,
    company_type                              text,
    company_founded                           int4,
    company_industry                          text,
    company_industry_v2                       text,
    company_ticker                            text,
    company_website                           text,
    company_linkedin_url                      text,
    company_linkedin_id                       text,
    company_facebook_url                      text,
    company_twitter_url                       text
);

CREATE INDEX idx_pdl_person_companies_parsed_person_pdl_id  ON staging.pdl_person_companies_parsed USING btree (person_pdl_id);
CREATE INDEX idx_pdl_person_companies_parsed_company_pdl_id ON staging.pdl_person_companies_parsed USING btree (company_pdl_id);
CREATE INDEX idx_pdl_person_companies_parsed_partition_id   ON staging.pdl_person_companies_parsed USING btree (partition_id);

COMMENT ON TABLE staging.pdl_person_companies_parsed IS
    'PDL experience[].company flattened. One row per (raw.pdl_person record × experience entry). Source for pdl_person_companies_unique. Company HQ location lives in pdl_person_addresses_parsed (source_context = experience_company_hq).';


-- =============================================================================
-- pdl_person_schools_parsed
-- =============================================================================

CREATE TABLE staging.pdl_person_schools_parsed (
    -- Ingester provenance
    partition_id                              smallint,
    loaded_at                                 timestamptz,

    -- Source-record link (back to education entry that referenced this school)
    person_pdl_id                             text,
    education_idx                             int4,

    -- School sub-object scalars
    school_pdl_id                             text,
    school_name                               text,
    school_type                               text,
    school_domain                             text,
    school_website                            text,
    school_linkedin_url                       text,
    school_linkedin_id                        text,
    school_facebook_url                       text,
    school_twitter_url                        text
);

CREATE INDEX idx_pdl_person_schools_parsed_person_pdl_id  ON staging.pdl_person_schools_parsed USING btree (person_pdl_id);
CREATE INDEX idx_pdl_person_schools_parsed_school_pdl_id  ON staging.pdl_person_schools_parsed USING btree (school_pdl_id);
CREATE INDEX idx_pdl_person_schools_parsed_partition_id   ON staging.pdl_person_schools_parsed USING btree (partition_id);

COMMENT ON TABLE staging.pdl_person_schools_parsed IS
    'PDL education[].school flattened. One row per (raw.pdl_person record × education entry). Source for pdl_person_schools_unique. School location lives in pdl_person_addresses_parsed (source_context = education_school, coarse-grain only).';


-- =============================================================================
-- pdl_person_addresses_parsed
--
-- UNION ALL of 3 source paths: person_home, experience_company_hq,
-- education_school. source_idx is 0 for person_home (top-level) and
-- the experience_idx / education_idx for the nested paths. NOT NULL
-- so the unique constraint on the downstream _unique table covers all
-- rows. job_company_hq (4th potential source path) dropped as
-- redundant with the is_primary experience entry's company location.
-- See docs/design/15 decision #3.
-- =============================================================================

CREATE TABLE staging.pdl_person_addresses_parsed (
    -- Ingester provenance
    partition_id                              smallint,
    loaded_at                                 timestamptz,

    -- Source identity (natural key components for the _unique tier)
    person_pdl_id                             text,
    source_context                            text,
    source_idx                                int4,

    -- Location scalars (PDL location.*)
    name                                      text,
    locality                                  text,
    region                                    text,
    country                                   text,
    metro                                     text,
    continent                                 text,
    street_address                            text,
    address_line_2                            text,
    postal_code                               text,
    geo                                       text
);

CREATE INDEX idx_pdl_person_addresses_parsed_person_pdl_id ON staging.pdl_person_addresses_parsed USING btree (person_pdl_id);
CREATE INDEX idx_pdl_person_addresses_parsed_source        ON staging.pdl_person_addresses_parsed USING btree (source_context, source_idx);
CREATE INDEX idx_pdl_person_addresses_parsed_partition_id  ON staging.pdl_person_addresses_parsed USING btree (partition_id);

COMMENT ON TABLE staging.pdl_person_addresses_parsed IS
    'PDL addresses unified across 3 source paths via UNION ALL (Option A from docs/design/15 decision #3). source_context distinguishes person_home / experience_company_hq / education_school. source_idx is 0 for person_home; experience_idx / education_idx for nested paths. job_company_hq dropped as redundant with is_primary experience entry. Source for pdl_person_addresses_unique.';


-- =============================================================================
-- pdl_person_experience_unique
--
-- Dedup of pdl_person_experience_parsed by 4-column natural key
-- (person_pdl_id, company_pdl_id, start_year, title_name).
-- On a full delivery, adding title_name cut the remaining duplicate groups
-- of the 3-column key to a negligible handful — see
-- docs/design/15_pdl_staging_design.md.
--
-- Shape mirrors pdl_person_experience_parsed exactly. Same columns,
-- same types. UNIQUE constraint is the structural addition.
-- =============================================================================

CREATE TABLE staging.pdl_person_experience_unique (
    -- Ingester provenance (winning row's)
    partition_id                              smallint,
    loaded_at                                 timestamptz,

    -- Person link
    person_pdl_id                             text,
    experience_idx                            int4,

    -- Per-experience scalars
    start_year                                int4,
    end_year                                  int4,
    is_primary                                bool,
    summary                                   text,
    first_seen                                timestamptz,
    last_seen                                 timestamptz,
    num_sources                               int4,

    -- Title (title_name is the 4th component of the natural key)
    title_name                                text,
    title_role                                text,
    title_sub_role                            text,
    title_class                               text,
    title_levels                              jsonb,
    title_raw                                 jsonb,

    -- Company sub-object scalars (company_pdl_id is the 2nd component of the natural key)
    company_pdl_id                            text,
    company_name                              text,
    company_size                              text,
    company_type                              text,
    company_founded                           int4,
    company_industry                          text,
    company_industry_v2                       text,
    company_ticker                            text,
    company_website                           text,
    company_linkedin_url                      text,
    company_linkedin_id                       text,
    company_facebook_url                      text,
    company_twitter_url                       text,

    -- Company location (carried down from parsed per Option A; redundant with pdl_person_addresses_unique)
    company_location_name                     text,
    company_location_street_address           text,
    company_location_address_line_2           text,
    company_location_locality                 text,
    company_location_region                   text,
    company_location_country                  text,
    company_location_continent                text,
    company_location_metro                    text,
    company_location_postal_code              text,
    company_location_geo                      text,

    -- Multi-valued per-experience jsonb
    location_names                            jsonb,
    raw_names                                 jsonb,

    CONSTRAINT uq_pdl_person_experience_unique_nk UNIQUE (person_pdl_id, company_pdl_id, start_year, title_name)
);

CREATE INDEX idx_pdl_person_experience_unique_company_pdl_id ON staging.pdl_person_experience_unique USING btree (company_pdl_id);

COMMENT ON TABLE staging.pdl_person_experience_unique IS
    'PDL experience deduplicated by 4-column natural key (person_pdl_id, company_pdl_id, start_year, title_name). Dedup ordering: loaded_at DESC, partition_id DESC (placeholder). NULL handling: rows with NULL in any key column survive un-deduped (Postgres treats each NULL as distinct). Source for integration.experience.';


-- =============================================================================
-- pdl_person_education_unique
--
-- Dedup of pdl_person_education_parsed by 4-column natural key
-- (person_pdl_id, school_pdl_id, start_year, degrees_text).
-- degrees_text is a STORED GENERATED column from degrees::text — needed
-- because Postgres UNIQUE constraints cannot be defined directly on a
-- jsonb expression. The degrees jsonb is preserved alongside (used by
-- integration); degrees_text is the dedup discriminator only.
--
-- On a full delivery, adding degrees_text cut the 3-column key's duplicate
-- groups substantially — see
-- docs/design/15_pdl_staging_design.md.
-- =============================================================================

CREATE TABLE staging.pdl_person_education_unique (
    -- Ingester provenance (winning row's)
    partition_id                              smallint,
    loaded_at                                 timestamptz,

    -- Person link
    person_pdl_id                             text,
    education_idx                             int4,

    -- Per-education scalars
    start_year                                int4,
    end_year                                  int4,
    gpa                                       numeric(4,2),
    summary                                   text,

    -- Multi-valued jsonb (degrees is the source of degrees_text)
    degrees                                   jsonb,
    degrees_text                              text GENERATED ALWAYS AS (degrees::text) STORED,
    majors                                    jsonb,
    minors                                    jsonb,
    raw_names                                 jsonb,

    -- School sub-object scalars (school_pdl_id is the 2nd component of the natural key)
    school_pdl_id                             text,
    school_name                               text,
    school_type                               text,
    school_domain                             text,
    school_website                            text,
    school_linkedin_url                       text,
    school_linkedin_id                        text,
    school_facebook_url                       text,
    school_twitter_url                        text,

    -- School location (coarse-grain only — carried down from parsed per Option A; redundant with pdl_person_addresses_unique)
    school_location_continent                 text,
    school_location_country                   text,
    school_location_region                    text,
    school_location_locality                  text,

    CONSTRAINT uq_pdl_person_education_unique_nk UNIQUE (person_pdl_id, school_pdl_id, start_year, degrees_text)
);

CREATE INDEX idx_pdl_person_education_unique_school_pdl_id ON staging.pdl_person_education_unique USING btree (school_pdl_id);

COMMENT ON TABLE staging.pdl_person_education_unique IS
    'PDL education deduplicated by 4-column natural key (person_pdl_id, school_pdl_id, start_year, degrees_text). degrees_text is a stored generated column from degrees::text — needed because Postgres UNIQUE cannot be defined directly on a jsonb expression. Dedup ordering: loaded_at DESC, partition_id DESC. Source for integration.person_education.';

COMMENT ON COLUMN staging.pdl_person_education_unique.degrees_text IS
    'STORED GENERATED column: degrees::text. Dedup discriminator only. Integration consumes degrees jsonb, not this column.';


-- =============================================================================
-- pdl_person_companies_unique
--
-- Dedup of pdl_person_companies_parsed by company_pdl_id. One row per
-- unique company across all (person × experience) source rows.
-- Per-row source provenance (person_pdl_id, experience_idx) is dropped —
-- this is per-company canonical, not per-occurrence.
--
-- The dbt model filters company_pdl_id IS NOT NULL (rows from experiences
-- PDL didn't link to a tracked company don't contribute to the company dim).
-- The NOT NULL constraint on the column enforces this at the DB level.
-- =============================================================================

CREATE TABLE staging.pdl_person_companies_unique (
    -- Ingester provenance (winning row's)
    partition_id                              smallint,
    loaded_at                                 timestamptz,

    -- Natural key
    company_pdl_id                            text NOT NULL,

    -- Company attributes
    company_name                              text,
    company_size                              text,
    company_type                              text,
    company_founded                           int4,
    company_industry                          text,
    company_industry_v2                       text,
    company_ticker                            text,
    company_website                           text,
    company_linkedin_url                      text,
    company_linkedin_id                       text,
    company_facebook_url                      text,
    company_twitter_url                       text,

    CONSTRAINT uq_pdl_person_companies_unique_nk UNIQUE (company_pdl_id)
);

COMMENT ON TABLE staging.pdl_person_companies_unique IS
    'PDL companies deduplicated by company_pdl_id. One row per unique company across all (person × experience) source rows. dbt model filters company_pdl_id IS NOT NULL. Source for integration.company.';


-- =============================================================================
-- pdl_person_schools_unique
--
-- Dedup of pdl_person_schools_parsed by school_pdl_id. Same pattern as
-- companies_unique. dbt model filters school_pdl_id IS NOT NULL.
-- =============================================================================

CREATE TABLE staging.pdl_person_schools_unique (
    -- Ingester provenance (winning row's)
    partition_id                              smallint,
    loaded_at                                 timestamptz,

    -- Natural key
    school_pdl_id                             text NOT NULL,

    -- School attributes
    school_name                               text,
    school_type                               text,
    school_domain                             text,
    school_website                            text,
    school_linkedin_url                       text,
    school_linkedin_id                        text,
    school_facebook_url                       text,
    school_twitter_url                        text,

    CONSTRAINT uq_pdl_person_schools_unique_nk UNIQUE (school_pdl_id)
);

COMMENT ON TABLE staging.pdl_person_schools_unique IS
    'PDL schools deduplicated by school_pdl_id. One row per unique school across all (person × education) source rows. dbt model filters school_pdl_id IS NOT NULL. Source for integration.school.';


-- =============================================================================
-- pdl_person_addresses_unique
--
-- Dedup of pdl_person_addresses_parsed by (person_pdl_id, source_context,
-- source_idx). Natural key IS the row's identity in the source PDL record,
-- not its content — matches integration.address design which explicitly
-- has no UNIQUE on content. Content dedup happens (or deliberately not)
-- at ref.location / integration.address downstream.
-- =============================================================================

CREATE TABLE staging.pdl_person_addresses_unique (
    -- Ingester provenance (winning row's)
    partition_id                              smallint,
    loaded_at                                 timestamptz,

    -- Natural key
    person_pdl_id                             text NOT NULL,
    source_context                            text NOT NULL,
    source_idx                                int4 NOT NULL,

    -- Location scalars
    name                                      text,
    locality                                  text,
    region                                    text,
    country                                   text,
    metro                                     text,
    continent                                 text,
    street_address                            text,
    address_line_2                            text,
    postal_code                               text,
    geo                                       text,

    CONSTRAINT uq_pdl_person_addresses_unique_nk UNIQUE (person_pdl_id, source_context, source_idx)
);

CREATE INDEX idx_pdl_person_addresses_unique_person_pdl_id ON staging.pdl_person_addresses_unique USING btree (person_pdl_id);

COMMENT ON TABLE staging.pdl_person_addresses_unique IS
    'PDL addresses deduplicated by (person_pdl_id, source_context, source_idx). One row per source-position identity. Source for integration.address per-entity rows and ref.location hierarchy population.';


-- =============================================================================
-- pdl_person_unique cleanup — drop 52 redundant columns
--
-- Two groups, both duplicates with cleaner homes:
--
--   41 current-job-flat columns (job_title, job_title_*, job_onet_*,
--   job_company_*, job_company_location_*): duplicate $.experience[*]
--   entries where is_primary=true. Canonical home for "current job" is
--   staging.pdl_person_experience_unique where is_primary=true;
--   integration models pick current-job rows from there.
--
--   11 person-home location columns (location_name, location_locality,
--   location_region, location_country, location_metro, location_continent,
--   location_street_address, location_address_line_2, location_postal_code,
--   location_geo, location_last_updated): person-home addresses live in
--   staging.pdl_person_addresses_parsed / _unique with
--   source_context = 'person_home'. (Note: location_street_address and
--   location_address_line_2 are PDL bool placeholders — "false"/"true",
--   never real addresses on the PDL field bundle this pipeline receives;
--   they would never have been usable here anyway.)
--
-- Zero data-loss risk: staging.pdl_person_unique was empty when this
-- migration landed (its dbt model was being rewritten). This cleanup aligns
-- the table shape with the new dbt model SELECT before the rewrite lands.
--
-- These same columns remain on staging.pdl_person_parsed for now (the
-- Option A additive-only path above). Removing them from pdl_person_parsed
-- is the Option B follow-up.
-- =============================================================================

ALTER TABLE staging.pdl_person_unique
  -- 41 current-job-flat columns
  DROP COLUMN IF EXISTS job_title,
  DROP COLUMN IF EXISTS job_title_role,
  DROP COLUMN IF EXISTS job_title_sub_role,
  DROP COLUMN IF EXISTS job_title_class,
  DROP COLUMN IF EXISTS job_start_year,
  DROP COLUMN IF EXISTS job_last_changed,
  DROP COLUMN IF EXISTS job_last_verified,
  DROP COLUMN IF EXISTS job_summary,
  DROP COLUMN IF EXISTS job_onet_code,
  DROP COLUMN IF EXISTS job_onet_major_group,
  DROP COLUMN IF EXISTS job_onet_minor_group,
  DROP COLUMN IF EXISTS job_onet_broad_occupation,
  DROP COLUMN IF EXISTS job_onet_specific_occupation,
  DROP COLUMN IF EXISTS job_onet_specific_occupation_detail,
  DROP COLUMN IF EXISTS job_company_name,
  DROP COLUMN IF EXISTS job_company_id,
  DROP COLUMN IF EXISTS job_company_website,
  DROP COLUMN IF EXISTS job_company_industry,
  DROP COLUMN IF EXISTS job_company_industry_v2,
  DROP COLUMN IF EXISTS job_company_size,
  DROP COLUMN IF EXISTS job_company_type,
  DROP COLUMN IF EXISTS job_company_founded,
  DROP COLUMN IF EXISTS job_company_employee_count,
  DROP COLUMN IF EXISTS job_company_inferred_revenue,
  DROP COLUMN IF EXISTS job_company_total_funding_raised,
  DROP COLUMN IF EXISTS job_company_ticker,
  DROP COLUMN IF EXISTS job_company_linkedin_url,
  DROP COLUMN IF EXISTS job_company_linkedin_id,
  DROP COLUMN IF EXISTS job_company_facebook_url,
  DROP COLUMN IF EXISTS job_company_twitter_url,
  DROP COLUMN IF EXISTS job_company_12mo_employee_growth_rate,
  DROP COLUMN IF EXISTS job_company_location_name,
  DROP COLUMN IF EXISTS job_company_location_street_address,
  DROP COLUMN IF EXISTS job_company_location_address_line_2,
  DROP COLUMN IF EXISTS job_company_location_locality,
  DROP COLUMN IF EXISTS job_company_location_region,
  DROP COLUMN IF EXISTS job_company_location_country,
  DROP COLUMN IF EXISTS job_company_location_continent,
  DROP COLUMN IF EXISTS job_company_location_metro,
  DROP COLUMN IF EXISTS job_company_location_postal_code,
  DROP COLUMN IF EXISTS job_company_location_geo,
  -- 11 person-home location columns
  DROP COLUMN IF EXISTS location_name,
  DROP COLUMN IF EXISTS location_street_address,
  DROP COLUMN IF EXISTS location_address_line_2,
  DROP COLUMN IF EXISTS location_locality,
  DROP COLUMN IF EXISTS location_region,
  DROP COLUMN IF EXISTS location_country,
  DROP COLUMN IF EXISTS location_continent,
  DROP COLUMN IF EXISTS location_metro,
  DROP COLUMN IF EXISTS location_postal_code,
  DROP COLUMN IF EXISTS location_geo,
  DROP COLUMN IF EXISTS location_last_updated;


-- =============================================================================
-- ref.* leaf tables — drop display_name column
--
-- display_name was intended as the title-case English version of name_lc,
-- to be populated by a future ISO/canonical seed migration. That
-- third-party canonical data is unlikely to land, so the column is dead
-- weight. Removing it keeps the schema tight.
--
-- Zero data-loss risk: these tables were empty when this migration landed
-- (no dbt model populated them yet).
--
-- Note: ISO/MSA "advisory" columns (ref.country.iso_alpha_2 etc.,
-- ref.state_province.iso_subdivision_code, ref.metro.msa_code) are KEPT
-- — they may still be valuable as cross-source join keys if PDL or
-- another source eventually emits them. They are currently NULL.
-- =============================================================================

ALTER TABLE ref.continent       DROP COLUMN IF EXISTS display_name;
ALTER TABLE ref.country         DROP COLUMN IF EXISTS display_name;
ALTER TABLE ref.state_province  DROP COLUMN IF EXISTS display_name;
ALTER TABLE ref.city            DROP COLUMN IF EXISTS display_name;
ALTER TABLE ref.metro           DROP COLUMN IF EXISTS display_name;
