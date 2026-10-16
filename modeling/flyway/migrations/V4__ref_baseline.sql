-- =============================================================================
-- V4__ref_baseline.sql — canonical reference dimensions (place hierarchy,
-- industry, job-title hierarchy, seniority, personal-attribute dims).
--
-- GENERATED FROM DBML. Source: modeling/dbml/ref.dbml.
-- Regenerate via: python -m modeling.scaffolding.dbml_compiler (not yet
-- implemented). Until the compiler ships, this file is hand-authored against
-- the DBML spec; any drift between the two is a manual review concern.
--
-- Population: loader-populated from raw.pdl_person strings. Seed migrations
-- for ISO / MSA data are additive future work.
--
-- Hand-authored sidecar: V5__ref_unique_indexes.sql creates the COALESCE-based
-- UNIQUE indexes on ref.city and ref.location that DBML cannot express.
--
-- Doc references:
--   - docs/data_model/10_reference_tables.md  (ref pattern + seeding lifecycle)
--   - docs/data_model/12_location.md          (place hierarchy)
--   - docs/data_model/13_person.md §5         (person-attribute dims)
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS ref;

COMMENT ON SCHEMA ref IS
    'Canonical reference dimensions. Loader-populated from PDL '
    'data. Future seed migrations land '
    'additively for ISO/MSA standards.';

-- -----------------------------------------------------------------------------
-- Place hierarchy (doc 12)
-- -----------------------------------------------------------------------------

CREATE TABLE ref.continent (
    id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name_lc             text        NOT NULL UNIQUE,
    display_name        text,
    timestamp_created   timestamptz NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ref.continent IS
    'Continents. Loader-populated from PDL location.continent strings; ~7 rows. '
    'Future seed migration possible but unnecessary.';
COMMENT ON COLUMN ref.continent.name_lc IS
    'PDL canonical lowercase English ("north america", "europe", etc.).';

CREATE TABLE ref.country (
    id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name_lc             text        NOT NULL UNIQUE,
    continent_id        bigint      REFERENCES ref.continent(id),
    iso_alpha_2         text,
    iso_alpha_3         text,
    display_name        text,
    timestamp_created   timestamptz NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ref.country IS
    'Country dimension. Loader-populated; an ISO seed migration is '
    'future work.';
COMMENT ON COLUMN ref.country.name_lc IS
    'PDL canonical lowercase English ("united states"). Join key from PDL data.';
COMMENT ON COLUMN ref.country.continent_id IS
    'Advisory; populated by future seed migration. Currently NULL.';
COMMENT ON COLUMN ref.country.iso_alpha_2 IS
    'Advisory ISO 3166-1 alpha-2 code; future seed migration.';
COMMENT ON COLUMN ref.country.iso_alpha_3 IS
    'Advisory ISO 3166-1 alpha-3 code; future seed migration.';

CREATE TABLE ref.state_province (
    id                     bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_id             bigint      NOT NULL REFERENCES ref.country(id),
    name_lc                text        NOT NULL,
    iso_subdivision_code   text,
    display_name           text,
    timestamp_created      timestamptz NOT NULL DEFAULT now(),
    timestamp_modified     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT state_province_country_id_name_lc_uk UNIQUE (country_id, name_lc)
);
CREATE INDEX idx_state_province_country_id ON ref.state_province (country_id);
COMMENT ON TABLE ref.state_province IS
    'State / province / top-level subdivision (ISO 3166-2 scope). '
    'Loader-populated; an ISO 3166-2 seed migration is future work.';
COMMENT ON COLUMN ref.state_province.name_lc IS
    'PDL canonical region string, lowercased ("california").';
COMMENT ON COLUMN ref.state_province.iso_subdivision_code IS
    'Advisory ISO 3166-2 ("US-CA"); future seed migration.';

CREATE TABLE ref.city (
    id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_id          bigint      NOT NULL REFERENCES ref.country(id),
    state_province_id   bigint      REFERENCES ref.state_province(id),
    name_lc             text        NOT NULL,
    display_name        text,
    timestamp_created   timestamptz NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz NOT NULL DEFAULT now()
    -- UNIQUE on (country_id, COALESCE(state_province_id, 0), name_lc) created
    -- in V5__ref_unique_indexes.sql (DBML cannot express COALESCE in indexes).
);
CREATE INDEX idx_city_country_id        ON ref.city (country_id);
CREATE INDEX idx_city_state_province_id ON ref.city (state_province_id);
COMMENT ON TABLE ref.city IS
    'City. Loader-populated only (no practical seed source at this grain). '
    'state_province_id NULL when PDL emits city without region. The widest '
    'place dimension at PDL scale.';
COMMENT ON COLUMN ref.city.name_lc IS
    'PDL canonical city string, lowercased ("san francisco").';

CREATE TABLE ref.metro (
    id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_id          bigint      NOT NULL REFERENCES ref.country(id),
    name_lc             text        NOT NULL,
    msa_code            text,
    display_name        text,
    timestamp_created   timestamptz NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT metro_country_id_name_lc_uk UNIQUE (country_id, name_lc)
);
CREATE INDEX idx_metro_country_id ON ref.metro (country_id);
COMMENT ON TABLE ref.metro IS
    'Metro area. PDL canon as join key; Census MSA codes added advisorially '
    'by future seed migration.';
COMMENT ON COLUMN ref.metro.name_lc IS
    'PDL canonical metro string ("san francisco bay area").';
COMMENT ON COLUMN ref.metro.msa_code IS
    'Advisory US Census MSA code; future seed migration (US only).';

CREATE TABLE ref.location (
    id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_id          bigint      NOT NULL REFERENCES ref.country(id),
    state_province_id   bigint      REFERENCES ref.state_province(id),
    city_id             bigint      REFERENCES ref.city(id),
    metro_id            bigint      REFERENCES ref.metro(id),
    timestamp_created   timestamptz NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz NOT NULL DEFAULT now()
    -- UNIQUE on (country_id, COALESCE(state_province_id, 0),
    --           COALESCE(city_id, 0), COALESCE(metro_id, 0)) created
    -- in V5__ref_unique_indexes.sql (DBML cannot express COALESCE in indexes).
);
CREATE INDEX idx_location_country_id        ON ref.location (country_id);
CREATE INDEX idx_location_state_province_id ON ref.location (state_province_id);
CREATE INDEX idx_location_city_id           ON ref.location (city_id);
CREATE INDEX idx_location_metro_id          ON ref.location (metro_id);
COMMENT ON TABLE ref.location IS
    'Composite-FK grain row — one per distinct (country, state_province, '
    'city, metro) tuple PDL emits. NULLs upward in the hierarchy.';

-- -----------------------------------------------------------------------------
-- Industry classifications (doc 13 §5.1)
-- -----------------------------------------------------------------------------

CREATE TABLE ref.industry (
    id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name                text        NOT NULL UNIQUE,
    source_type         text        NOT NULL,
    timestamp_created   timestamptz NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ref.industry IS
    'Industry dimension. PDL canonical v1 industry enum.';
COMMENT ON COLUMN ref.industry.source_type IS
    '''pdl'' — provenance tag.';

CREATE TABLE ref.industry_v2 (
    id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name                text        NOT NULL UNIQUE,
    timestamp_created   timestamptz NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ref.industry_v2 IS
    'Industry v2 — PDL expanded canonical industry enum. PDL-sourced only.';

-- -----------------------------------------------------------------------------
-- Job-title hierarchy (doc 13 §5.2)
-- -----------------------------------------------------------------------------

CREATE TABLE ref.job_title_class (
    id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name                text        NOT NULL UNIQUE,
    timestamp_created   timestamptz NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ref.job_title_class IS
    'PDL canonical job-title class (top-level category).';

CREATE TABLE ref.job_title_role (
    id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name                text        NOT NULL UNIQUE,
    timestamp_created   timestamptz NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ref.job_title_role IS
    'PDL canonical job-title role.';

CREATE TABLE ref.job_title_subrole (
    id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name                text        NOT NULL UNIQUE,
    timestamp_created   timestamptz NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ref.job_title_subrole IS
    'PDL canonical job-title sub-role.';

CREATE TABLE ref.job_title_classification (
    id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    org_class           text        NOT NULL REFERENCES ref.job_title_class(name),
    role                text        NOT NULL REFERENCES ref.job_title_role(name),
    sub_role            text        NOT NULL REFERENCES ref.job_title_subrole(name),
    timestamp_created   timestamptz NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT job_title_classification_uk UNIQUE (org_class, role, sub_role)
);
COMMENT ON TABLE ref.job_title_classification IS
    'Composite of (org_class, role, sub_role). Canonical FK target from '
    'integration.experience.job_title_classification_id. Text FK pattern '
    'matches doc 13 ERD; could be normalized to bigint FKs later.';

-- -----------------------------------------------------------------------------
-- Seniority (doc 13 §5.3)
-- -----------------------------------------------------------------------------

CREATE TABLE ref.seniority_level (
    id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name                text        NOT NULL UNIQUE,
    timestamp_created   timestamptz NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ref.seniority_level IS
    'PDL canonical seniority level. Junctioned via '
    'integration.experience_seniority_level (M:N).';

-- -----------------------------------------------------------------------------
-- Personal-attribute dimensions (doc 13 §5.4)
-- -----------------------------------------------------------------------------

CREATE TABLE ref.skill (
    id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name                text        NOT NULL,
    type                text,
    timestamp_created   timestamptz NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_skill_name ON ref.skill (name);
COMMENT ON TABLE ref.skill IS
    'PDL skills[]. Junctioned via integration.person_skill. No UNIQUE on '
    'name — PDL skill strings are noisy; cross-source dedup is '
    'future work.';

CREATE TABLE ref.interest (
    id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name                text,
    type                text,
    timestamp_created   timestamptz NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ref.interest IS
    'PDL interests[]. Junctioned via integration.person_interest.';

CREATE TABLE ref.language (
    id                  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name                text        NOT NULL UNIQUE,
    timestamp_created   timestamptz NOT NULL DEFAULT now(),
    timestamp_modified  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ref.language IS
    'PDL languages[].name. Junctioned via integration.person_language. '
    'PDL proficiency (1-5) is dropped.';
