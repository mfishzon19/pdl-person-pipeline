-- =============================================================================
-- V35 — pdl_api location cleaner (/v5/location/clean).
--
-- HAND-AUTHORED (per the repo's schema rules, the pdl_api operational schema
-- is hand-authored Flyway content, same as V3). Mirrors the company cleaner
-- trio in V3__pdl_api_company_enrichment.sql, renamed for the location
-- domain, with the simpler shape from docs/design/18_pdl_api_generic_caller.md:
-- single-status queue keyed on raw_input (no source_list /
-- passthrough_params), single-record audit (no bulk_batch_id).
--
-- Three objects:
--   pdl_api.location_input_list   — queue + state, one row per raw address
--   pdl_api.location_cleaner_call — append-only audit of /v5/location/clean
--   pdl_api.v_location_input      — cleaner workload (pending only)
--
-- Consumed by processing/pdl_api/location_cleaner.py (LocationCleanerCaller).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. location_input_list — queue + state.
-- -----------------------------------------------------------------------------

CREATE TABLE pdl_api.location_input_list (
    id             bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    raw_input      text          NOT NULL UNIQUE,
    cleaner_status text          NOT NULL DEFAULT 'pending',
    worker_id      text,
    claimed_at     timestamptz,
    created_at     timestamptz   NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT location_input_list_cleaner_status_check CHECK (
        cleaner_status IN ('pending', 'in_progress', 'resolved',
                           'not_found', 'error')
    )
);

COMMENT ON TABLE pdl_api.location_input_list IS
    'Queue + state for the location cleaner. One row per distinct raw address '
    'string (raw_input UNIQUE dedups across sources). Populated by '
    'INSERT ... SELECT DISTINCT ... ON CONFLICT (raw_input) DO NOTHING from '
    'whatever table holds the raw values; no dbt model populates it yet '
    '(docs/design/18_pdl_api_generic_caller.md, "Queue population").';

CREATE INDEX location_input_list_pending_idx
    ON pdl_api.location_input_list (cleaner_status)
    WHERE cleaner_status = 'pending';


-- -----------------------------------------------------------------------------
-- 2. location_cleaner_call — append-only audit. Single-record endpoint, one
--    row per HTTP call.
--
--    IMPORTANT: /v5/location/clean returns NO top-level id (unlike company /
--    school clean). Its 200 body is {status, name, locality, region, country,
--    geo, ...}; PDL canonicalizes a location by its composite NAME, not an
--    entity id. So the canonical identifier we persist is `cleaned_location`,
--    extracted from response_json->>'name' (e.g. "austin, texas, united states").
--    (Verified against the live PDL API.)
-- -----------------------------------------------------------------------------

CREATE TABLE pdl_api.location_cleaner_call (
    id              bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    input_list_id   bigint        NOT NULL
                                  REFERENCES pdl_api.location_input_list (id),
    endpoint        text          NOT NULL,
    request_json    jsonb         NOT NULL,
    response_status smallint,
    response_json   jsonb,
    called_at       timestamptz   NOT NULL DEFAULT clock_timestamp(),
    latency_ms      int,
    error_message   text,

    cleaned_location text         GENERATED ALWAYS AS
                                  (response_json->>'name') STORED
);

COMMENT ON TABLE pdl_api.location_cleaner_call IS
    'Append-only audit of every PDL /v5/location/clean call. PDL-level '
    '"no match" is response_status=404 (not error_message).';
COMMENT ON COLUMN pdl_api.location_cleaner_call.cleaned_location IS
    'Canonical composite location name from response_json->>''name'' (e.g. '
    '"austin, texas, united states"). /v5/location/clean returns no entity id, '
    'so locations canonicalize by name, not by a pdl_location_id.';

CREATE INDEX location_cleaner_call_cleaned_location_idx
    ON pdl_api.location_cleaner_call (cleaned_location);
CREATE INDEX location_cleaner_call_input_list_id_idx
    ON pdl_api.location_cleaner_call (input_list_id);
CREATE INDEX location_cleaner_call_called_at_idx
    ON pdl_api.location_cleaner_call (called_at);


-- -----------------------------------------------------------------------------
-- 3. v_location_input — cleaner workload. Exposes the standardized
--    (input_list_id, endpoint, request_payload) shape the generic PDLCaller
--    claims through. request_payload is the /v5/location/clean body.
-- -----------------------------------------------------------------------------

CREATE VIEW pdl_api.v_location_input AS
SELECT id                                       AS input_list_id,
       '/v5/location/clean'                     AS endpoint,
       jsonb_build_object('location', raw_input) AS request_payload
FROM   pdl_api.location_input_list
WHERE  cleaner_status = 'pending';

COMMENT ON VIEW pdl_api.v_location_input IS
    'Workload for the location cleaner pass — pending inputs only. Worker '
    'claims a batch FOR UPDATE SKIP LOCKED, calls /v5/location/clean, writes '
    'audit + flips cleaner_status to resolved/not_found/error.';
