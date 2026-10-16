-- =============================================================================
-- V6__integration_baseline.sql — conformed entity tables (person, company,
-- school, experience, address) + all junctions.
--
-- GENERATED FROM DBML. Source: modeling/dbml/integration.dbml.
-- Regenerate via: python -m modeling.scaffolding.dbml_compiler (not yet
-- implemented). Until the compiler ships, this file is hand-authored against
-- the DBML spec; any drift is a manual review concern.
--
-- Architectural note: integration.* table DDL is Flyway-managed (this file);
-- dbt models populate these pre-existing tables via
-- materialized='incremental' rather than materialized='table'
-- (docs/design/02 §11, "Division of ownership between Flyway and dbt").
--
-- Population:
--   - PDL-sourced: integration.person, experience, person_education,
--     school, company (basic columns; enrichment-only scalars stay NULL),
--     address, all PDL-fed junctions.
--
-- Cross-system identifiers do NOT live on integration.person — they belong
-- in catalog.person_key_map. Doc 13 §7.
--
-- Doc references:
--   - docs/data_model/08_company.md — integration.company (both source shapes)
--   - docs/data_model/12_location.md — integration.address + ref.location FKs
--   - docs/data_model/13_person.md  — integration.person + junctions
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS integration;

COMMENT ON SCHEMA integration IS
    'Conformed entity tables — single source of truth for Person, Company, '
    'School, Experience. Rebuilt from raw + catalog ledger on every pipeline '
    'run. Surrogate IDs are not stable across rebuilds; downstream uses '
    'natural keys (pdl_id) or internal_person_id from catalog.person_key_map.';

-- =============================================================================
-- Core entities
-- =============================================================================

-- -----------------------------------------------------------------------------
-- integration.address — entity-specific street-level data (later inlined
-- and dropped in V20/V21/V24; see doc 12 §4.7)
-- -----------------------------------------------------------------------------

CREATE TABLE integration.address (
    id                  bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    location_id         bigint        NOT NULL REFERENCES ref.location(id),
    street_address      text,
    address_line_2      text,
    postal_code         text,
    latitude            numeric(9,6),
    longitude           numeric(9,6),
    timestamp_created   timestamptz   NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX idx_address_location_id ON integration.address (location_id);
COMMENT ON TABLE integration.address IS
    'Entity-specific street-level data. No UNIQUE constraint — formatting '
    'variance across sources makes cross-entity dedup not worth fighting. '
    'No is_current / pdl_last_updated columns — stateless rebuild means '
    'every row is current by construction.';
COMMENT ON COLUMN integration.address.latitude IS
    'Parsed from PDL location.geo ("47.56,-122.33").';

-- -----------------------------------------------------------------------------
-- integration.person — the hub (doc 13 §4.1)
-- -----------------------------------------------------------------------------

CREATE TABLE integration.person (
    id                          bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pdl_id                      text          NOT NULL UNIQUE,
    first_name                  text,
    middle_name                 text,
    middle_initial              text,
    last_name                   text,
    last_initial                text,
    full_name                   text,
    headline                    text,
    summary                     text,
    industry_id                 bigint        REFERENCES ref.industry(id),
    linkedin_id                 text,
    linkedin_url                text,
    linkedin_username           text,
    linkedin_connections        int4,
    location_id                 bigint        REFERENCES ref.location(id),
    address_id                  bigint        REFERENCES integration.address(id),
    sex                         text,
    work_email                  text,
    mobile_phone                text,
    inferred_years_experience   int4,
    dataset_version             text,
    first_seen                  timestamptz,
    num_sources                 int4,
    num_records                 int4,
    timestamp_created           timestamptz   NOT NULL DEFAULT now(),
    timestamp_modified          timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX idx_person_full_name      ON integration.person (full_name);
CREATE INDEX idx_person_linkedin_id    ON integration.person (linkedin_id);
CREATE INDEX idx_person_linkedin_url   ON integration.person (linkedin_url);
CREATE INDEX idx_person_industry_id    ON integration.person (industry_id);
CREATE INDEX idx_person_location_id    ON integration.person (location_id);
CREATE INDEX idx_person_address_id     ON integration.person (address_id);
COMMENT ON TABLE integration.person IS
    'Conformed Person. Cross-system identifiers live in '
    'catalog.person_key_map — NOT on this table. '
    'No birth_date / emails[] / phone_numbers[] — PII excluded by design.';
COMMENT ON COLUMN integration.person.pdl_id IS
    'PDL natural key. UNIQUE NOT NULL — loaders ON CONFLICT (pdl_id) DO UPDATE.';
COMMENT ON COLUMN integration.person.mobile_phone IS
    'PDL mobile_phone. PII — open question doc 13 §9 Q1.';
COMMENT ON COLUMN integration.person.first_seen IS
    'PDL first_seen — when the record entered PDL.';

-- -----------------------------------------------------------------------------
-- integration.company (doc 08 — full both-source scalar schema)
-- -----------------------------------------------------------------------------

CREATE TABLE integration.company (
    id                              bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pdl_company_id                  text          NOT NULL UNIQUE,
    source                          text          NOT NULL,

    -- Scalar columns populated from person.experience.company
    name                            text,
    size                            text,
    founded                         smallint,
    industry                        text,
    industry_v2                     text,
    type                            text,
    website                         text,
    linkedin_id                     text,
    linkedin_url                    text,
    facebook_url                    text,
    twitter_url                     text,
    ticker                          text,

    -- Scalar columns populated only by company enrichment
    display_name                    text,
    linkedin_slug                   text,
    mic_exchange                    text,
    summary                         text,
    headline                        text,
    employee_count                  int4,
    inferred_revenue                text,
    immediate_parent_id             bigint        REFERENCES integration.company(id),
    ultimate_parent_id              bigint        REFERENCES integration.company(id),
    total_funding_raised            bigint,
    latest_funding_stage            text,
    last_funding_date               date,
    number_funding_rounds           smallint,
    dataset_version                 text,
    likelihood                      smallint,

    -- Common — populated by both sources
    location_id                     bigint        REFERENCES ref.location(id),
    address_id                      bigint        REFERENCES integration.address(id),
    fetched_at                      timestamptz,
    timestamp_created               timestamptz   NOT NULL DEFAULT now(),
    timestamp_modified              timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX idx_company_name                ON integration.company (name);
CREATE INDEX idx_company_ticker              ON integration.company (ticker);
CREATE INDEX idx_company_website             ON integration.company (website);
CREATE INDEX idx_company_linkedin_id         ON integration.company (linkedin_id);
CREATE INDEX idx_company_location_id         ON integration.company (location_id);
CREATE INDEX idx_company_immediate_parent_id ON integration.company (immediate_parent_id);
CREATE INDEX idx_company_ultimate_parent_id  ON integration.company (ultimate_parent_id);
COMMENT ON TABLE integration.company IS
    'Conformed Company. Experience-sourced columns come from '
    'person.experience.company; company enrichment fills the rest. Junction / '
    'multi-valued data (affiliations, NAICS, SIC, tags, etc.) added in V28.';
COMMENT ON COLUMN integration.company.source IS
    '''person_experience'' | ''enrichment''. '
    'Provenance of latest write.';
COMMENT ON COLUMN integration.company.mic_exchange IS
    'enrichment-only — NULL unless enriched. Plain text; no FK to a '
    'ref table.';
COMMENT ON COLUMN integration.company.immediate_parent_id IS
    'enrichment-only — NULL unless enriched. Unknown parents are later '
    'handled by the V28 stub-insert pattern (doc 08 §6.4).';

-- -----------------------------------------------------------------------------
-- integration.school (doc 13 §4.4)
-- -----------------------------------------------------------------------------

CREATE TABLE integration.school (
    id                  bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pdl_id              text          NOT NULL UNIQUE,
    name                text,
    domain              text,
    type                text,
    website             text,
    linkedin_id         text,
    linkedin_url        text,
    facebook_url        text,
    twitter_url         text,
    location_id         bigint        REFERENCES ref.location(id),
    timestamp_created   timestamptz   NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX idx_school_name         ON integration.school (name);
CREATE INDEX idx_school_domain       ON integration.school (domain);
CREATE INDEX idx_school_linkedin_id  ON integration.school (linkedin_id);
CREATE INDEX idx_school_location_id  ON integration.school (location_id);
COMMENT ON TABLE integration.school IS
    'PDL education[].school. No address_id — PDL emits no street-level data '
    'for schools (location grain is continent/country/region/locality only).';

-- -----------------------------------------------------------------------------
-- integration.experience — junction of person × company + role attrs (doc 13 §4.2)
-- -----------------------------------------------------------------------------

CREATE TABLE integration.experience (
    id                              bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    person_id                       bigint        NOT NULL REFERENCES integration.person(id),
    company_id                      bigint        REFERENCES integration.company(id),
    start_date                      timestamptz,
    end_date                        timestamptz,
    title                           text,
    job_title_classification_id     bigint        REFERENCES ref.job_title_classification(id),
    is_primary                      bool,
    summary                         text,
    timestamp_created               timestamptz   NOT NULL DEFAULT now(),
    timestamp_modified              timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX idx_experience_person_id                   ON integration.experience (person_id);
CREATE INDEX idx_experience_company_id                  ON integration.experience (company_id);
CREATE INDEX idx_experience_classification_id           ON integration.experience (job_title_classification_id);
CREATE INDEX idx_experience_start_date                  ON integration.experience (start_date);
CREATE INDEX idx_experience_is_primary                  ON integration.experience (is_primary);
CREATE INDEX idx_experience_title                       ON integration.experience (title);
COMMENT ON TABLE integration.experience IS
    'PDL experience[]. Title columns trimmed to raw title + classification FK '
    '(doc 13 §4.2). Trigram index on title is a future hand-authored '
    'sidecar migration (DBML cannot express GIN/trgm).';
COMMENT ON COLUMN integration.experience.company_id IS
    'NULL when PDL emits experience without a company.id.';
COMMENT ON COLUMN integration.experience.end_date IS
    'NULL = current position.';
COMMENT ON COLUMN integration.experience.title IS
    'Raw PDL experience.title.name.';

-- -----------------------------------------------------------------------------
-- integration.person_education (doc 13 §4.3)
-- -----------------------------------------------------------------------------

CREATE TABLE integration.person_education (
    id                  bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    person_id           bigint        NOT NULL REFERENCES integration.person(id),
    school_id           bigint        REFERENCES integration.school(id),
    start_date          timestamptz,
    end_date            timestamptz,
    degrees             jsonb,
    majors              jsonb,
    minors              jsonb,
    gpa                 numeric(4,2),
    summary             text,
    timestamp_created   timestamptz   NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX idx_person_education_person_id ON integration.person_education (person_id);
CREATE INDEX idx_person_education_school_id ON integration.person_education (school_id);
COMMENT ON TABLE integration.person_education IS
    'PDL education[]. degrees/majors/minors stay jsonb (per-education arrays; '
    'no useful cross-entity grouping).';

-- =============================================================================
-- Person — multi-valued attribute junctions (PDL-sourced; doc 13 §4.10-§4.13)
-- =============================================================================

CREATE TABLE integration.person_country (
    person_id           bigint        NOT NULL REFERENCES integration.person(id),
    country_id          bigint        NOT NULL REFERENCES ref.country(id),
    timestamp_created   timestamptz   NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz   NOT NULL DEFAULT now(),

    PRIMARY KEY (person_id, country_id)
);
CREATE INDEX idx_person_country_country_id ON integration.person_country (country_id);
COMMENT ON TABLE integration.person_country IS
    'PDL countries[] — derived set of all countries associated with the person.';

CREATE TABLE integration.person_state_province (
    person_id           bigint        NOT NULL REFERENCES integration.person(id),
    state_province_id   bigint        NOT NULL REFERENCES ref.state_province(id),
    timestamp_created   timestamptz   NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz   NOT NULL DEFAULT now(),

    PRIMARY KEY (person_id, state_province_id)
);
CREATE INDEX idx_person_state_province_state_province_id
    ON integration.person_state_province (state_province_id);
COMMENT ON TABLE integration.person_state_province IS
    'PDL regions[] — derived set of all regions associated with the person.';

CREATE TABLE integration.person_location (
    person_id           bigint        NOT NULL REFERENCES integration.person(id),
    location_id         bigint        NOT NULL REFERENCES ref.location(id),
    timestamp_created   timestamptz   NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz   NOT NULL DEFAULT now(),

    PRIMARY KEY (person_id, location_id)
);
CREATE INDEX idx_person_location_location_id ON integration.person_location (location_id);
COMMENT ON TABLE integration.person_location IS
    'PDL location_names[] resolved through ref.location chain.';

CREATE TABLE integration.person_skill (
    person_id           bigint        NOT NULL REFERENCES integration.person(id),
    skill_id            bigint        NOT NULL REFERENCES ref.skill(id),
    timestamp_created   timestamptz   NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz   NOT NULL DEFAULT now(),

    PRIMARY KEY (person_id, skill_id)
);
CREATE INDEX idx_person_skill_skill_id ON integration.person_skill (skill_id);
COMMENT ON TABLE integration.person_skill IS 'PDL skills[].';

CREATE TABLE integration.person_interest (
    person_id           bigint        NOT NULL REFERENCES integration.person(id),
    interest_id         bigint        NOT NULL REFERENCES ref.interest(id),
    timestamp_created   timestamptz   NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz   NOT NULL DEFAULT now(),

    PRIMARY KEY (person_id, interest_id)
);
CREATE INDEX idx_person_interest_interest_id ON integration.person_interest (interest_id);
COMMENT ON TABLE integration.person_interest IS 'PDL interests[].';

CREATE TABLE integration.person_language (
    person_id     bigint  NOT NULL REFERENCES integration.person(id),
    language_id   bigint  NOT NULL REFERENCES ref.language(id),

    PRIMARY KEY (person_id, language_id)
);
COMMENT ON TABLE integration.person_language IS
    'PDL languages[]. PDL proficiency (1-5) is dropped; add proficiency '
    'int4 column when downstream needs it.';

CREATE TABLE integration.person_social_network (
    person_id           bigint        NOT NULL REFERENCES integration.person(id),
    network             text          NOT NULL,
    profile_id          text,
    username            text,
    url                 text,
    first_seen          timestamptz,
    last_seen           timestamptz,
    num_sources         int4,
    timestamp_created   timestamptz   NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz   NOT NULL DEFAULT now(),

    PRIMARY KEY (person_id, network)
);
CREATE INDEX idx_person_social_network_person_id ON integration.person_social_network (person_id);
COMMENT ON TABLE integration.person_social_network IS
    'PDL profiles[]. One row per (person, network). LinkedIn lives on '
    'integration.person.linkedin_* as the canonical primary.';
COMMENT ON COLUMN integration.person_social_network.network IS
    'PDL profiles[].network — "facebook", "twitter", "github", etc.';

CREATE TABLE integration.person_name_alias (
    person_id           bigint        NOT NULL REFERENCES integration.person(id),
    alias               text          NOT NULL,
    timestamp_created   timestamptz   NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz   NOT NULL DEFAULT now(),

    PRIMARY KEY (person_id, alias)
);
COMMENT ON TABLE integration.person_name_alias IS
    'PDL name_aliases[]. Aliases vary too much to canonicalize — no ref '
    'table.';

CREATE TABLE integration.person_certification (
    id                  bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    person_id           bigint        NOT NULL REFERENCES integration.person(id),
    name                text          NOT NULL,
    organization        text,
    start_date          timestamptz,
    end_date            timestamptz,
    timestamp_created   timestamptz   NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX idx_person_certification_person_id ON integration.person_certification (person_id);
COMMENT ON TABLE integration.person_certification IS
    'PDL certifications[] — child table (each cert has organization + dates '
    'as attributes). Open: promote '
    'name+organization to ref.certification table when canonical cert '
    'lookups (PMP, CISSP) become a query pattern.';

-- =============================================================================
-- Experience — multi-valued attribute junctions (doc 13 §4.7-§4.9)
-- =============================================================================

CREATE TABLE integration.experience_location (
    experience_id       bigint        NOT NULL REFERENCES integration.experience(id),
    location_id         bigint        NOT NULL REFERENCES ref.location(id),
    timestamp_created   timestamptz   NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz   NOT NULL DEFAULT now(),

    PRIMARY KEY (experience_id, location_id)
);
CREATE INDEX idx_experience_location_location_id ON integration.experience_location (location_id);
COMMENT ON TABLE integration.experience_location IS
    'PDL experience[].location_names[] resolved through ref.location.';

CREATE TABLE integration.experience_industry (
    experience_id       bigint        NOT NULL REFERENCES integration.experience(id),
    industry_id         bigint        NOT NULL REFERENCES ref.industry(id),

    PRIMARY KEY (experience_id, industry_id)
);
CREATE INDEX idx_experience_industry_industry_id ON integration.experience_industry (industry_id);
COMMENT ON TABLE integration.experience_industry IS
    'Multi-valued industries per experience role. Empty unless '
    'downstream tagging populates.';

CREATE TABLE integration.experience_seniority_level (
    experience_id       bigint        NOT NULL REFERENCES integration.experience(id),
    seniority_level_id  bigint        NOT NULL REFERENCES ref.seniority_level(id),
    timestamp_created   timestamptz   NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz   NOT NULL DEFAULT now(),

    PRIMARY KEY (experience_id, seniority_level_id)
);
CREATE INDEX idx_experience_seniority_level_seniority_level_id
    ON integration.experience_seniority_level (seniority_level_id);
COMMENT ON TABLE integration.experience_seniority_level IS
    'PDL experience[].title.levels[] — a title can map to multiple levels '
    '("manager" + "director").';
