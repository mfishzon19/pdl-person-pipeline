-- =============================================================================
-- V7__staging_baseline.sql — staging schema baseline.
--
-- HAND-AUTHORED. Generated downstream from modeling/dbml/staging.dbml.
-- Regenerate via: python -m modeling.scaffolding.dbml_compiler (not yet
-- implemented). Until the compiler ships, this file is hand-authored against
-- the DBML spec; any drift is a manual review concern.
--
-- Creates the staging schema and its founding table set: the full PDL
-- person staging surface (parsed + unique). Later staging tables ship as
-- their own V<n>__staging_<table>.sql migrations after this baseline (e.g.
-- the V12 _unique tables; staging.pdl_api_company_* landed with V28).
--
-- Seven tables in the staging schema (all PDL person):
--   staging.pdl_person_parsed                — top-level scalar flatten
--                                              via JSON_TABLE (1:1 with
--                                              raw); simple text arrays
--                                              kept here as jsonb
--   staging.pdl_person_experience_parsed     — experience[] unnest via
--                                              JSON_TABLE NESTED PATH
--   staging.pdl_person_education_parsed      — education[] unnest +
--                                              school sub-object
--   staging.pdl_person_profiles_parsed       — profiles[] unnest (social
--                                              networks superset)
--   staging.pdl_person_certifications_parsed — certifications[] unnest
--   staging.pdl_person_languages_parsed      — languages[] unnest with
--                                              proficiency (integration
--                                              drops it;
--                                              staging keeps for source
--                                              fidelity)
--   staging.pdl_person_unique                — dedup + single-hop alias
--                                              resolution; UNIQUE on
--                                              pdl_id
--
-- Simple text arrays (name_aliases, skills, interests, location_names,
-- countries, regions) live as jsonb columns on pdl_person_parsed — no
-- per-entry sub-object to type, so they don't warrant their own _parsed
-- table. dbt integration loaders unnest at consume time via
-- jsonb_array_elements_text() and upsert against the ref tables; dedup
-- happens at the ref upsert (ON CONFLICT DO NOTHING).
--
-- _unique variants for the array tables (experience_unique, education_unique,
-- etc.) are deferred — they need per-array dedup-key design that depends
-- on the real PDL data shape. Each will ship as its own V<n> migration
-- after the natural keys are settled (they did, in V12).
--
-- Population: dbt models in processing/dbt/models/staging/<source>/ populate
-- these tables via materialized='incremental' + incremental_strategy='append'
-- + pre_hook='TRUNCATE ... RESTART IDENTITY CASCADE'. Stateless content
-- rebuild semantics (docs/requirements/01 §2): full rebuild on every dbt run.
--
-- DDL ownership: Flyway (this file). dbt populates pre-existing tables;
-- never DROPs. on_schema_change='fail' in dbt catches drift between this
-- DDL and the dbt model SELECT shape.
--
-- Schema creation: staging is auto-created by Flyway via `flyway.schemas`
-- in flyway.conf. The CREATE SCHEMA IF NOT EXISTS below is a
-- belt-and-suspenders no-op for fresh DBs where Flyway happens to run this
-- migration before the schema list is processed.
--
-- Doc references:
--   - docs/design/02_pipeline_design.md §8       (staging layer responsibilities)
--   - docs/design/02_pipeline_design.md §11      (Flyway/dbt ownership division)
--   - docs/data_model/13_person.md §6     (PDL person field inventory)
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS staging;

COMMENT ON SCHEMA staging IS
    'Per-source staging tables — parsed/unique/staged pattern (docs/design/02 §8). '
    'DDL Flyway-owned; data populated by dbt incremental + truncate. '
    'Stateless rebuild semantics per docs/requirements/01 §2.';


-- -----------------------------------------------------------------------------
-- staging.pdl_person_parsed — PDL person top-level scalar flatten.
--
-- One row per raw.pdl_person record (1:1 with raw). All top-level scalars
-- PDL emits, even fields integration drops (job_company_*, job_onet_*,
-- social-network duplicates of profiles[]). No PK — multiple rows per
-- pdl_id allowed (dedup at pdl_person_unique).
-- -----------------------------------------------------------------------------

CREATE TABLE staging.pdl_person_parsed (
    -- Ingester provenance
    partition_id                              smallint,
    loaded_at                                 timestamptz,

    -- Record metadata
    pdl_id                                    text,
    first_seen                                timestamptz,
    num_sources                               int4,
    num_records                               int4,
    dataset_version                           text,
    operation_id                              text,

    -- Names
    first_name                                text,
    middle_name                               text,
    middle_initial                            text,
    last_name                                 text,
    last_initial                              text,
    full_name                                 text,

    -- Bio
    headline                                  text,
    summary                                   text,
    industry                                  text,
    sex                                       text,

    -- Inferred
    inferred_years_experience                 int4,
    inferred_salary                           text,

    -- Contact (PII-allowed subset)
    work_email                                text,
    mobile_phone                              text,

    -- Current job (flat — duplicate of experience[is_primary])
    job_title                                 text,
    job_title_role                            text,
    job_title_sub_role                        text,
    job_title_class                           text,
    job_start_date                            date,
    job_last_changed                          date,
    job_last_verified                         date,
    job_summary                               text,

    -- O*NET federal occupational codes
    job_onet_code                             text,
    job_onet_major_group                      text,
    job_onet_minor_group                      text,
    job_onet_broad_occupation                 text,
    job_onet_specific_occupation              text,
    job_onet_specific_occupation_detail       text,

    -- Current company (flat — duplicate of experience[is_primary].company)
    job_company_name                          text,
    job_company_id                            text,
    job_company_website                       text,
    job_company_industry                      text,
    job_company_industry_v2                   text,
    job_company_size                          text,
    job_company_type                          text,
    job_company_founded                       int4,
    job_company_employee_count                int4,
    job_company_inferred_revenue              text,
    job_company_total_funding_raised          int8,
    job_company_ticker                        text,
    job_company_linkedin_url                  text,
    job_company_linkedin_id                   text,
    job_company_facebook_url                  text,
    job_company_twitter_url                   text,
    job_company_12mo_employee_growth_rate     numeric(7,4),

    -- Current company location (flat)
    job_company_location_name                 text,
    job_company_location_street_address       text,
    job_company_location_address_line_2       text,
    job_company_location_locality             text,
    job_company_location_region               text,
    job_company_location_country              text,
    job_company_location_continent            text,
    job_company_location_metro                text,
    job_company_location_postal_code          text,
    job_company_location_geo                  text,

    -- Social — LinkedIn at top level (canonical primary)
    linkedin_id                               text,
    linkedin_url                              text,
    linkedin_username                         text,
    linkedin_connections                      int4,

    -- Social — duplicated by profiles[] junction in integration
    facebook_id                               text,
    facebook_url                              text,
    facebook_username                         text,
    facebook_friends                          int4,
    twitter_url                               text,
    twitter_username                          text,
    github_url                                text,
    github_username                           text,

    -- Person home location (flat)
    location_name                             text,
    location_street_address                   text,
    location_address_line_2                   text,
    location_locality                         text,
    location_region                           text,
    location_country                          text,
    location_continent                        text,
    location_metro                            text,
    location_postal_code                      text,
    location_geo                              text,
    location_last_updated                     date,

    -- Simple text arrays kept as jsonb (no per-entry sub-object). Integration
    -- loaders unnest via jsonb_array_elements_text() to populate ref tables
    -- and junction tables. Dedup at the ref upsert layer (ON CONFLICT DO
    -- NOTHING) — no staging _unique needed.
    name_aliases                              jsonb,   -- → integration.person_name_alias
    skills                                    jsonb,   -- → ref.skill + integration.person_skill
    interests                                 jsonb,   -- → ref.interest + integration.person_interest
    location_names                            jsonb,   -- → ref.location + integration.person_location
    countries                                 jsonb,   -- → ref.country + integration.person_country
    regions                                   jsonb    -- → ref.state_province + integration.person_state_province
);

CREATE INDEX idx_pdl_person_parsed_pdl_id       ON staging.pdl_person_parsed (pdl_id);
CREATE INDEX idx_pdl_person_parsed_partition_id ON staging.pdl_person_parsed (partition_id);

COMMENT ON TABLE staging.pdl_person_parsed IS
    'PDL person top-level scalar flatten — one row per raw.pdl_person '
    'record. No PK (multiple rows per pdl_id allowed across deliveries; '
    'dedup at pdl_person_unique). Populated by '
    'processing/dbt/models/staging/pdl_person/pdl_person_parsed.sql via '
    'JSON_TABLE.';


-- -----------------------------------------------------------------------------
-- staging.pdl_person_experience_parsed — PDL experience[] array unnest.
--
-- Demonstrates the NESTED PATH unnest pattern (JSON_TABLE NESTED PATH +
-- FOR ORDINALITY) used for sub-object arrays (education[], profiles[],
-- certifications[], languages[]) — see below. Simple text arrays (skills,
-- interests, name_aliases, location_names, countries, regions) skip the
-- _parsed table and live as jsonb columns on pdl_person_parsed instead.
-- One row per (raw.pdl_person record × experience entry).
-- -----------------------------------------------------------------------------

CREATE TABLE staging.pdl_person_experience_parsed (
    -- Ingester provenance
    partition_id                              smallint,
    loaded_at                                 timestamptz,

    -- Person link
    person_pdl_id                             text,
    experience_idx                            int4,

    -- Per-experience scalars
    start_date                                date,
    end_date                                  date,
    is_primary                                bool,
    summary                                   text,
    first_seen                                timestamptz,
    last_seen                                 timestamptz,
    num_sources                               int4,

    -- Title
    title_name                                text,
    title_role                                text,
    title_sub_role                            text,
    title_class                               text,
    title_levels                              jsonb,
    title_raw                                 jsonb,

    -- Company sub-object
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

    -- Company location (per-experience.company.location)
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

    -- Multi-valued per-experience attributes (kept as jsonb)
    location_names                            jsonb,
    raw_names                                 jsonb
);

CREATE INDEX idx_pdl_person_experience_parsed_person_pdl_id
    ON staging.pdl_person_experience_parsed (person_pdl_id);
CREATE INDEX idx_pdl_person_experience_parsed_company_pdl_id
    ON staging.pdl_person_experience_parsed (company_pdl_id);
CREATE INDEX idx_pdl_person_experience_parsed_partition_id
    ON staging.pdl_person_experience_parsed (partition_id);

COMMENT ON TABLE staging.pdl_person_experience_parsed IS
    'PDL experience[] unnested via JSON_TABLE NESTED PATH. One row per '
    '(raw.pdl_person record × experience entry). Multi-valued sub-fields '
    '(title.levels, location_names, raw) kept as jsonb — integration '
    'projects them to junctions. No PK; dedup at pdl_person_experience_unique. '
    'Populated by processing/dbt/models/staging/pdl_person/pdl_person_experience_parsed.sql.';


-- -----------------------------------------------------------------------------
-- staging.pdl_person_education_parsed — PDL education[] array unnest.
--
-- One row per (raw.pdl_person record × education entry). degrees/majors/
-- minors/raw_names kept as jsonb (multi-valued; integration unnests at
-- consume time). School sub-object is flattened into school_* scalars
-- including a coarse-grain school location (continent / country / region /
-- locality only — PDL does not emit street-level for schools, per
-- docs/data_model/13_person.md §4.4).
-- -----------------------------------------------------------------------------

CREATE TABLE staging.pdl_person_education_parsed (
    -- Ingester provenance
    partition_id                              smallint,
    loaded_at                                 timestamptz,

    -- Person link
    person_pdl_id                             text,
    education_idx                             int4,

    -- Per-education scalars
    start_date                                date,
    end_date                                  date,
    gpa                                       numeric(4,2),
    summary                                   text,

    -- Multi-valued per-education attributes (kept as jsonb)
    degrees                                   jsonb,
    majors                                    jsonb,
    minors                                    jsonb,
    raw_names                                 jsonb,

    -- School sub-object (scalars)
    school_pdl_id                             text,
    school_name                               text,
    school_type                               text,
    school_domain                             text,
    school_website                            text,
    school_linkedin_url                       text,
    school_linkedin_id                        text,
    school_facebook_url                       text,
    school_twitter_url                        text,

    -- School location (coarse-grain only — no street/metro/postal/geo)
    school_location_continent                 text,
    school_location_country                   text,
    school_location_region                    text,
    school_location_locality                  text
);

CREATE INDEX idx_pdl_person_education_parsed_person_pdl_id
    ON staging.pdl_person_education_parsed (person_pdl_id);
CREATE INDEX idx_pdl_person_education_parsed_school_pdl_id
    ON staging.pdl_person_education_parsed (school_pdl_id);
CREATE INDEX idx_pdl_person_education_parsed_partition_id
    ON staging.pdl_person_education_parsed (partition_id);

COMMENT ON TABLE staging.pdl_person_education_parsed IS
    'PDL education[] unnested via JSON_TABLE NESTED PATH. One row per '
    '(raw.pdl_person record × education entry). degrees/majors/minors/raw '
    'kept as jsonb. School location is coarse-grain only (PDL does not '
    'emit street-level for schools). No PK; dedup at pdl_person_education_unique. '
    'Populated by processing/dbt/models/staging/pdl_person/pdl_person_education_parsed.sql.';


-- -----------------------------------------------------------------------------
-- staging.pdl_person_profiles_parsed — PDL profiles[] array unnest.
--
-- One row per (raw.pdl_person record × profile entry). Each entry is one
-- social-network profile: network (facebook / twitter / github / …), the
-- network's account id / url / username, plus PDL's first-seen metadata.
-- LinkedIn at the top level of person remains the canonical primary
-- (mirrored in pdl_person_parsed.linkedin_*).
-- -----------------------------------------------------------------------------

CREATE TABLE staging.pdl_person_profiles_parsed (
    -- Ingester provenance
    partition_id                              smallint,
    loaded_at                                 timestamptz,

    -- Person link
    person_pdl_id                             text,
    profile_idx                               int4,

    -- Per-profile scalars
    network                                   text,
    profile_id                                text,
    url                                       text,
    username                                  text,
    first_seen                                timestamptz,
    last_seen                                 timestamptz,
    num_sources                               int4
);

CREATE INDEX idx_pdl_person_profiles_parsed_person_pdl_id
    ON staging.pdl_person_profiles_parsed (person_pdl_id);
CREATE INDEX idx_pdl_person_profiles_parsed_partition_id
    ON staging.pdl_person_profiles_parsed (partition_id);

COMMENT ON TABLE staging.pdl_person_profiles_parsed IS
    'PDL profiles[] unnested via JSON_TABLE NESTED PATH. One row per '
    '(raw.pdl_person record × profile entry). Feeds '
    'integration.person_social_network (superset of LinkedIn-on-person). '
    'No PK; dedup at pdl_person_profiles_unique.';


-- -----------------------------------------------------------------------------
-- staging.pdl_person_certifications_parsed — PDL certifications[] array unnest.
--
-- One row per (raw.pdl_person record × certification entry). Each entry
-- has its own attributes (name, issuing organization, validity dates).
-- Kept as a flat child table (per docs/data_model/13 §9 Q2);
-- ref-junction promotion is a future question if cert names need
-- canonicalization.
-- -----------------------------------------------------------------------------

CREATE TABLE staging.pdl_person_certifications_parsed (
    -- Ingester provenance
    partition_id                              smallint,
    loaded_at                                 timestamptz,

    -- Person link
    person_pdl_id                             text,
    certification_idx                         int4,

    -- Per-certification scalars
    name                                      text,
    organization                              text,
    start_date                                date,
    end_date                                  date
);

CREATE INDEX idx_pdl_person_certifications_parsed_person_pdl_id
    ON staging.pdl_person_certifications_parsed (person_pdl_id);
CREATE INDEX idx_pdl_person_certifications_parsed_partition_id
    ON staging.pdl_person_certifications_parsed (partition_id);

COMMENT ON TABLE staging.pdl_person_certifications_parsed IS
    'PDL certifications[] unnested via JSON_TABLE NESTED PATH. One row per '
    '(raw.pdl_person record × certification entry). Feeds '
    'integration.person_certification (flat child table). '
    'No PK; dedup at pdl_person_certifications_unique.';


-- -----------------------------------------------------------------------------
-- staging.pdl_person_languages_parsed — PDL languages[] array unnest.
--
-- One row per (raw.pdl_person record × language entry). Includes
-- proficiency (1-5) for source fidelity, even though integration
-- drops it (per docs/data_model/13 §6.6 / §9 Q3). Keeping it in staging
-- lets later work promote it without re-flattening raw.
-- -----------------------------------------------------------------------------

CREATE TABLE staging.pdl_person_languages_parsed (
    -- Ingester provenance
    partition_id                              smallint,
    loaded_at                                 timestamptz,

    -- Person link
    person_pdl_id                             text,
    language_idx                              int4,

    -- Per-language scalars
    language_name                             text,
    proficiency                               int4
);

CREATE INDEX idx_pdl_person_languages_parsed_person_pdl_id
    ON staging.pdl_person_languages_parsed (person_pdl_id);
CREATE INDEX idx_pdl_person_languages_parsed_partition_id
    ON staging.pdl_person_languages_parsed (partition_id);

COMMENT ON TABLE staging.pdl_person_languages_parsed IS
    'PDL languages[] unnested via JSON_TABLE NESTED PATH. One row per '
    '(raw.pdl_person record × language entry). proficiency (1-5) preserved '
    'in staging; integration drops it. No PK; dedup at '
    'pdl_person_languages_unique.';


-- -----------------------------------------------------------------------------
-- staging.pdl_person_unique — deduplicated + alias-resolved PDL persons.
--
-- One row per current pdl_id. Reads pdl_person_parsed via dbt
-- (catalog.pdl_id_aliases via dbt source) and produces this table via:
--
--   1. Single-hop alias resolution: COALESCE(aliases.current_pdl_id, p.pdl_id)
--   2. Dedup: DISTINCT ON (pdl_id) ORDER BY loaded_at DESC, partition_id DESC
--
-- pdl_id has a UNIQUE constraint here (DDL-level guarantee, matches dbt
-- schema.yml unique test as belt-and-suspenders).
-- -----------------------------------------------------------------------------

CREATE TABLE staging.pdl_person_unique (
    -- Ingester provenance
    partition_id                              smallint,
    loaded_at                                 timestamptz,

    -- Record metadata
    pdl_id                                    text,
    first_seen                                timestamptz,
    num_sources                               int4,
    num_records                               int4,
    dataset_version                           text,
    operation_id                              text,

    -- Names
    first_name                                text,
    middle_name                               text,
    middle_initial                            text,
    last_name                                 text,
    last_initial                              text,
    full_name                                 text,

    -- Bio
    headline                                  text,
    summary                                   text,
    industry                                  text,
    sex                                       text,

    -- Inferred
    inferred_years_experience                 int4,
    inferred_salary                           text,

    -- Contact (PII-allowed subset)
    work_email                                text,
    mobile_phone                              text,

    -- Current job (flat)
    job_title                                 text,
    job_title_role                            text,
    job_title_sub_role                        text,
    job_title_class                           text,
    job_start_date                            date,
    job_last_changed                          date,
    job_last_verified                         date,
    job_summary                               text,

    -- O*NET federal occupational codes
    job_onet_code                             text,
    job_onet_major_group                      text,
    job_onet_minor_group                      text,
    job_onet_broad_occupation                 text,
    job_onet_specific_occupation              text,
    job_onet_specific_occupation_detail       text,

    -- Current company (flat)
    job_company_name                          text,
    job_company_id                            text,
    job_company_website                       text,
    job_company_industry                      text,
    job_company_industry_v2                   text,
    job_company_size                          text,
    job_company_type                          text,
    job_company_founded                       int4,
    job_company_employee_count                int4,
    job_company_inferred_revenue              text,
    job_company_total_funding_raised          int8,
    job_company_ticker                        text,
    job_company_linkedin_url                  text,
    job_company_linkedin_id                   text,
    job_company_facebook_url                  text,
    job_company_twitter_url                   text,
    job_company_12mo_employee_growth_rate     numeric(7,4),

    -- Current company location (flat)
    job_company_location_name                 text,
    job_company_location_street_address       text,
    job_company_location_address_line_2       text,
    job_company_location_locality             text,
    job_company_location_region               text,
    job_company_location_country              text,
    job_company_location_continent            text,
    job_company_location_metro                text,
    job_company_location_postal_code          text,
    job_company_location_geo                  text,

    -- Social — LinkedIn at top level
    linkedin_id                               text,
    linkedin_url                              text,
    linkedin_username                         text,
    linkedin_connections                      int4,

    -- Social — other
    facebook_id                               text,
    facebook_url                              text,
    facebook_username                         text,
    facebook_friends                          int4,
    twitter_url                               text,
    twitter_username                          text,
    github_url                                text,
    github_username                           text,

    -- Person home location (flat)
    location_name                             text,
    location_street_address                   text,
    location_address_line_2                   text,
    location_locality                         text,
    location_region                           text,
    location_country                          text,
    location_continent                        text,
    location_metro                            text,
    location_postal_code                      text,
    location_geo                              text,
    location_last_updated                     date,

    -- Simple text arrays kept as jsonb (mirrors pdl_person_parsed).
    name_aliases                              jsonb,
    skills                                    jsonb,
    interests                                 jsonb,
    location_names                            jsonb,
    countries                                 jsonb,
    regions                                   jsonb,

    CONSTRAINT pdl_person_unique_pdl_id_uk UNIQUE (pdl_id)
);

CREATE INDEX idx_pdl_person_unique_partition_id ON staging.pdl_person_unique (partition_id);

COMMENT ON TABLE staging.pdl_person_unique IS
    'PDL person, deduplicated + alias-resolved. One row per current pdl_id. '
    'UNIQUE constraint on pdl_id at DDL level (matches dbt unique test as '
    'belt-and-suspenders). Populated by '
    'processing/dbt/models/staging/pdl_person/pdl_person_unique.sql.';
