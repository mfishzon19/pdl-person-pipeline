-- =============================================================================
-- V28 — PDL Company Enrichment schema
--
-- Lands the full schema for company enrichment + multi-source merge:
--   1. staging.pdl_api_company_parsed   (NEW — flatten of enrichment responses)
--   2. staging.pdl_api_company_unique   (NEW — empty; activated when re-enrichment lands)
--   3. ref.pdl_relationship             (NEW — loader-discovered, 4 values)
--   4. integration.company              (DROP + CREATE — adds 8 jsonb cols in
--                                         logical column order; rewrites with
--                                         3-value source enum)
--   5. integration.company_affiliation  (NEW — junction with subject_company_id,
--                                         relationship_id FK, nullable status_id
--                                         + catalyst_id, dataset_version)
--
-- WHY DROP + CREATE on integration.company:
--   Postgres ALTER TABLE ADD COLUMN always appends at the end, leaving the
--   physical column order out of sync with the logical/DBML order. V28 is
--   adding 8 jsonb columns that belong in a specific position (after enrichment
--   scalars, before location). The only way to land them correctly is DROP +
--   CREATE. Acceptable because:
--     (a) the project is local-only and rebuilds from an empty database
--     (b) stateless-rebuild architecture repopulates everything from
--         staging on the next dbt run (TRUNCATE + INSERT is the daily pattern
--         anyway — this migration just makes it required once)
--     (c) FK chain to integration.company is dbt-managed per ADR-0009 — the
--         next dbt rebuild recreates all FKs to/from this table
--
-- BLAST RADIUS:
--   - Drops integration.company (and via CASCADE: the FK from
--     integration.experience.company_id to integration.company.id).
--   - Drops any pre-existing rows in integration.company. Repopulated on next
--     dbt build from staging.
--   - DBML in modeling/dbml/{integration,staging,ref}.dbml updated in the same change.
--   - Pattern 1 + 2 hooks landing in processing/dbt/dbt_project.yml in the same change.
--   - docs/data_model/08_company.md is the canonical schema reference.
--   - docs/design/18_pdl_api_generic_caller.md (sections "Running the callers +
--     pipeline decoupling" and "Concrete workflow") covers how dbt consumes
--     the enrichment audit.
--   - ADR-0011 (loader-discovered ref layer) governs the ref.pdl_relationship
--     decision.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Drop dependent objects (CASCADE clears FKs from other tables)
-- -----------------------------------------------------------------------------

DROP TABLE IF EXISTS integration.company_affiliation;
DROP TABLE IF EXISTS integration.company CASCADE;

-- -----------------------------------------------------------------------------
-- 1. staging.pdl_api_company_parsed — flatten of PDL Company Enrichment responses
-- -----------------------------------------------------------------------------

CREATE TABLE staging.pdl_api_company_parsed (
  -- Source-row provenance
  enrichment_call_id        bigint,
  bulk_batch_id             bigint,
  called_at                 timestamptz,

  -- Natural key (1:1 by API contract — each call returns one company response)
  pdl_company_id            text         NOT NULL,

  -- Shared scalars (also emitted by person.experience.company)
  name                      text,
  size                      text,
  founded                   int4,
  industry                  text,
  type                      text,
  website                   text,
  linkedin_id               text,
  linkedin_url              text,
  facebook_url              text,
  twitter_url               text,
  ticker                    text,

  -- Enrichment-only scalars
  display_name              text,
  linkedin_slug             text,
  mic_exchange              text,
  summary                   text,
  headline                  text,
  employee_count            int4,
  inferred_revenue          text,
  immediate_parent          text,
  ultimate_parent           text,
  total_funding_raised      bigint,
  latest_funding_stage      text,
  last_funding_date         date,
  number_funding_rounds     smallint,
  dataset_version           text,
  likelihood                smallint,

  -- Multi-valued enrichment (kept as jsonb at staging)
  naics                     jsonb,
  sic                       jsonb,
  tags                      jsonb,
  alternative_names         jsonb,
  alternative_domains       jsonb,
  funding_stages            jsonb,
  employee_count_by_country jsonb,
  profiles                  jsonb,
  affiliated_entities       jsonb,

  -- Location flattened from $.location (10-field shape)
  location_name             text,
  location_locality         text,
  location_region           text,
  location_country          text,
  location_continent        text,
  location_metro            text,
  location_postal_code      text,
  location_street_address   text,
  location_address_line_2   text,
  location_geo              text
);

CREATE UNIQUE INDEX uq_pdl_api_company_parsed_pdl_company_id
  ON staging.pdl_api_company_parsed (pdl_company_id);
CREATE INDEX idx_pdl_api_company_parsed_called_at
  ON staging.pdl_api_company_parsed (called_at DESC);
CREATE INDEX idx_pdl_api_company_parsed_bulk_batch_id
  ON staging.pdl_api_company_parsed (bulk_batch_id);

COMMENT ON TABLE staging.pdl_api_company_parsed IS
  'PDL Company Enrichment responses flattened. One row per pdl_company_id — UNIQUE because each Company Enrichment API call returns exactly one company response and re-enrichment is not implemented (1:1 by API contract). dbt unique test enforces. integration.company reads this directly; the _unique staging step is documented but stays empty until re-enrichment lands. See docs/design/18_pdl_api_generic_caller.md.';

-- -----------------------------------------------------------------------------
-- 2. staging.pdl_api_company_unique — EMPTY, deferred until re-enrichment lands
-- -----------------------------------------------------------------------------
--
-- Created here so DBML doesn't describe a state no migration has produced
-- (per the repo's schema rules: every DBML table ships with its migration). No dbt model populates this yet. When re-enrichment
-- arrives, add the _unique dbt model + switch integration.company.sql to read
-- from here. Mechanical change.

CREATE TABLE staging.pdl_api_company_unique (
  enrichment_call_id        bigint,
  bulk_batch_id             bigint,
  called_at                 timestamptz,
  pdl_company_id            text         NOT NULL,
  name                      text,
  size                      text,
  founded                   int4,
  industry                  text,
  type                      text,
  website                   text,
  linkedin_id               text,
  linkedin_url              text,
  facebook_url              text,
  twitter_url               text,
  ticker                    text,
  display_name              text,
  linkedin_slug             text,
  mic_exchange              text,
  summary                   text,
  headline                  text,
  employee_count            int4,
  inferred_revenue          text,
  immediate_parent          text,
  ultimate_parent           text,
  total_funding_raised      bigint,
  latest_funding_stage      text,
  last_funding_date         date,
  number_funding_rounds     smallint,
  dataset_version           text,
  likelihood                smallint,
  naics                     jsonb,
  sic                       jsonb,
  tags                      jsonb,
  alternative_names         jsonb,
  alternative_domains       jsonb,
  funding_stages            jsonb,
  employee_count_by_country jsonb,
  profiles                  jsonb,
  affiliated_entities       jsonb,
  location_name             text,
  location_locality         text,
  location_region           text,
  location_country          text,
  location_continent        text,
  location_metro            text,
  location_postal_code      text,
  location_street_address   text,
  location_address_line_2   text,
  location_geo              text
);

CREATE UNIQUE INDEX uq_pdl_api_company_unique_nk
  ON staging.pdl_api_company_unique (pdl_company_id);

COMMENT ON TABLE staging.pdl_api_company_unique IS
  'PDL Company Enrichment responses deduplicated by pdl_company_id. DEFERRED — currently empty. Activated when re-enrichment lands (multiple raw records per pdl_company_id makes dedup necessary). Pattern: DISTINCT ON (pdl_company_id) ORDER BY pdl_company_id, called_at DESC, enrichment_call_id DESC. integration.company currently reads staging.pdl_api_company_parsed directly. See docs/design/18_pdl_api_generic_caller.md.';

-- -----------------------------------------------------------------------------
-- 3. ref.pdl_relationship — loader-discovered (ADR-0011), 4 values
-- -----------------------------------------------------------------------------

CREATE TABLE ref.pdl_relationship (
  id                  bigint       PRIMARY KEY,
  relationship        text         NOT NULL UNIQUE,
  timestamp_created   timestamptz  NOT NULL DEFAULT now(),
  timestamp_modified  timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE ref.pdl_relationship IS
  'PDL company relationship type vocabulary. Loader-discovered from staging.pdl_api_company_parsed.affiliated_entities[].relationship per ADR-0011. Currently 4 observed values (direct_subsidiary, indirect_subsidiary, immediate_parent, ultimate_parent). New PDL values are picked up automatically on next rebuild. Surrogate id is dbt-computed via ROW_NUMBER OVER (ORDER BY relationship); not stable across rebuilds (ADR-0008). Future ref.pdl_relationship_status + ref.pdl_relationship_catalyst will be added when PDL emits the Parent Subsidiary Details extension.';

-- -----------------------------------------------------------------------------
-- 4. integration.company — full enrichment shape (DROP + CREATE for column order)
-- -----------------------------------------------------------------------------

CREATE TABLE integration.company (
  -- Surrogate + natural key
  id                          bigint       PRIMARY KEY,
  pdl_company_id              text         NOT NULL UNIQUE,
  source                      text         NOT NULL,

  -- Shared scalars (both sources emit; populated via COALESCE)
  name                        text,
  size                        text,
  founded                     smallint,
  industry_id                 bigint       REFERENCES ref.industry(id),
  industry_v2_id              bigint       REFERENCES ref.industry_v2(id),
  type                        text,
  website                     text,
  linkedin_id                 text,
  linkedin_url                text,
  facebook_url                text,
  twitter_url                 text,
  ticker                      text,

  -- Enrichment-only scalars (NULL for non-enriched + stub rows)
  display_name                text,
  linkedin_slug               text,
  mic_exchange                text,
  summary                     text,
  headline                    text,
  employee_count              int4,
  inferred_revenue            text,
  immediate_parent_id         bigint       REFERENCES integration.company(id),
  ultimate_parent_id          bigint       REFERENCES integration.company(id),
  total_funding_raised        bigint,
  latest_funding_stage        text,
  last_funding_date           date,
  number_funding_rounds       smallint,
  dataset_version             text,
  likelihood                  smallint,

  -- Multi-valued enrichment (V28 — jsonb on the entity, not separate junction tables)
  naics_codes                 jsonb,
  sic_codes                   jsonb,
  tags                        jsonb,
  alternative_names           jsonb,
  alternative_domains         jsonb,
  funding_stages              jsonb,
  employee_count_by_country   jsonb,
  profiles                    jsonb,

  -- Common location (both sources; V24 — inline address scalars)
  location_id                 bigint       REFERENCES ref.location(id),
  latitude                    numeric(9,6),
  longitude                   numeric(9,6),
  postal_code                 text,
  street_address              text,
  address_line_2              text,

  -- Operational metadata
  fetched_at                  timestamptz,
  timestamp_created           timestamptz  NOT NULL DEFAULT now(),
  timestamp_modified          timestamptz  NOT NULL DEFAULT now()
);

-- Indexes (V23 trim: 4 secondary + PK + UNIQUE = 6 total)
CREATE INDEX idx_company_name        ON integration.company (name);
CREATE INDEX idx_company_website     ON integration.company (website);
CREATE INDEX idx_company_location_id ON integration.company (location_id);
CREATE INDEX idx_company_industry_id ON integration.company (industry_id);

COMMENT ON TABLE integration.company IS
  'Conformed Company. Three sources populate this table via single-pass LEFT JOIN + COALESCE in dbt: (1) person.experience.company (the baseline — every company a person has worked at), (2) PDL Company Enrichment (the subset of companies enriched via the API), (3) affiliated_entities[] stubs (orphan companies referenced by an enriched company but not otherwise in our data — preserves graph integrity for the affiliation junction). 3-value source enum: person_experience | enrichment | affiliation_stub. See doc 08 §6.3-§6.4 and docs/design/18_pdl_api_generic_caller.md. V28 schema: 8 jsonb cols for multi-valued enrichment + stub-insert pattern.';

COMMENT ON COLUMN integration.company.source IS
  '''person_experience'' | ''enrichment'' | ''affiliation_stub''. Computed at SELECT time via CASE — highest fidelity wins (enr > pe > stub).';

COMMENT ON COLUMN integration.company.profiles IS
  'PDL Company Enrichment $.profiles[]. Array of multi-platform social URLs (LinkedIn, Twitter, Facebook, Crunchbase, etc.); network names kept as free text inside the array, not normalized. Distinct from the linkedin_url scalar (which only carries one LinkedIn). NULL when not enriched. V28.';

COMMENT ON COLUMN integration.company.immediate_parent_id IS
  'Self-FK. Source: PDL Company Enrichment $.immediate_parent (text scalar — the parent''s pdl_company_id, NOT a nested object). Resolved via LEFT JOIN. Always resolves under the stub-insert pattern (V28). Populated for a minority of enriched companies.';

COMMENT ON COLUMN integration.company.ultimate_parent_id IS
  'Self-FK. Same shape as immediate_parent_id; populated for a minority of enriched companies.';

-- -----------------------------------------------------------------------------
-- 5. integration.company_affiliation — junction (V28 new shape)
-- -----------------------------------------------------------------------------

CREATE TABLE integration.company_affiliation (
  subject_company_id    bigint       NOT NULL REFERENCES integration.company(id),
  affiliated_company_id bigint       NOT NULL REFERENCES integration.company(id),
  relationship_id       bigint       NOT NULL REFERENCES ref.pdl_relationship(id),
  status_id             bigint,
  catalyst_id           bigint,
  dataset_version       text,
  timestamp_created     timestamptz  NOT NULL DEFAULT now(),
  timestamp_modified    timestamptz  NOT NULL DEFAULT now(),
  PRIMARY KEY (subject_company_id, affiliated_company_id, relationship_id)
);

CREATE INDEX idx_company_affiliation_affiliated_company_id
  ON integration.company_affiliation (affiliated_company_id);
CREATE INDEX idx_company_affiliation_relationship_id
  ON integration.company_affiliation (relationship_id);

COMMENT ON TABLE integration.company_affiliation IS
  'Company hierarchy + parent/subsidiary relationships. Sourced exclusively from PDL Company Enrichment $.affiliated_entities[] (each element {affiliated_id, display_name, relationship} becomes one row). PDL''s sibling denormalizations are dropped — see doc 08 §5.2. INNER JOIN on both subject/affiliated company sides always resolves under V28 stub-insert pattern. display_name from the source element is NOT stored on the junction — derivable from integration.company.name on the affiliated row via JOIN. status_id + catalyst_id reserved nullable for the future Parent Subsidiary Details extension. dataset_version captures which enrichment response asserted the edge — for refresh diffing.';

COMMENT ON COLUMN integration.company_affiliation.status_id IS
  'Nullable. FK reserved for the future Parent Subsidiary Details extension — ref.pdl_relationship_status will be created when PDL starts emitting affiliated_entities[].status. Not yet a hard FK (ref table does not exist yet).';

COMMENT ON COLUMN integration.company_affiliation.catalyst_id IS
  'Nullable. FK reserved for the future Parent Subsidiary Details extension — ref.pdl_relationship_catalyst will be created when PDL starts emitting affiliated_entities[].catalyst. Not yet a hard FK.';

-- -----------------------------------------------------------------------------
-- NOTE: FK fk_experience_company_id (integration.experience.company_id →
--       integration.company.id) is INTENTIONALLY NOT re-added here.
--
-- The DROP TABLE CASCADE on integration.company removed it. The FK can't be
-- re-added in V28 because integration.experience still has pre-V28 company_id
-- values pointing at the OLD integration.company rows — the new
-- integration.company is empty, so any FK ADD would immediately violate.
--
-- Per ADR-0009, integration.* FKs are dbt-managed: dropped pre-INSERT,
-- recreated post-INSERT by dbt's hook chain. The next dbt run will:
--   1. TRUNCATE + INSERT integration.company (repopulates from staging)
--   2. TRUNCATE + INSERT integration.experience (computes fresh company_id
--      values via JOIN to the new integration.company)
--   3. Post-hooks ADD CONSTRAINT fk_experience_company_id (now resolves cleanly)
--
-- Between V28 apply and the next dbt run, integration.experience.company_id
-- references rows that no longer exist. Acceptable per the stateless-rebuild
-- architecture (integration data is ephemeral between rebuilds; no consumer
-- reads from integration.* mid-rebuild).
-- -----------------------------------------------------------------------------
