-- =============================================================================
-- V36 — pdl_api school cleaner (/v5/school/clean).
--
-- HAND-AUTHORED. Mirror of V35 (location cleaner) for the school domain. Same
-- shape from docs/design/18_pdl_api_generic_caller.md: raw_input-keyed
-- single-status queue, single-record audit with a generated pdl_school_id.
--
-- Three objects:
--   pdl_api.school_input_list   — queue + state, one row per raw school string
--   pdl_api.school_cleaner_call — append-only audit of /v5/school/clean
--   pdl_api.v_school_input      — cleaner workload (pending only)
--
-- Consumed by processing/pdl_api/school_cleaner.py (SchoolCleanerCaller).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. school_input_list — queue + state.
-- -----------------------------------------------------------------------------

CREATE TABLE pdl_api.school_input_list (
    id             bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    raw_input      text          NOT NULL UNIQUE,
    cleaner_status text          NOT NULL DEFAULT 'pending',
    worker_id      text,
    claimed_at     timestamptz,
    created_at     timestamptz   NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT school_input_list_cleaner_status_check CHECK (
        cleaner_status IN ('pending', 'in_progress', 'resolved',
                           'not_found', 'error')
    )
);

COMMENT ON TABLE pdl_api.school_input_list IS
    'Queue + state for the school cleaner. One row per distinct raw school '
    'string (raw_input UNIQUE dedups across sources). Populated by '
    'INSERT ... SELECT DISTINCT ... ON CONFLICT (raw_input) DO NOTHING from '
    'whatever table holds the raw values; no dbt model populates it yet '
    '(docs/design/18_pdl_api_generic_caller.md, "Queue population").';

CREATE INDEX school_input_list_pending_idx
    ON pdl_api.school_input_list (cleaner_status)
    WHERE cleaner_status = 'pending';


-- -----------------------------------------------------------------------------
-- 2. school_cleaner_call — append-only audit. pdl_school_id computed from
--    response_json.
-- -----------------------------------------------------------------------------

CREATE TABLE pdl_api.school_cleaner_call (
    id              bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    input_list_id   bigint        NOT NULL
                                  REFERENCES pdl_api.school_input_list (id),
    endpoint        text          NOT NULL,
    request_json    jsonb         NOT NULL,
    response_status smallint,
    response_json   jsonb,
    called_at       timestamptz   NOT NULL DEFAULT clock_timestamp(),
    latency_ms      int,
    error_message   text,

    pdl_school_id   text          GENERATED ALWAYS AS
                                  (response_json->>'id') STORED
);

COMMENT ON TABLE pdl_api.school_cleaner_call IS
    'Append-only audit of every PDL /v5/school/clean call. PDL-level '
    '"no match" is response_status=404 (not error_message).';

CREATE INDEX school_cleaner_call_pdl_school_id_idx
    ON pdl_api.school_cleaner_call (pdl_school_id);
CREATE INDEX school_cleaner_call_input_list_id_idx
    ON pdl_api.school_cleaner_call (input_list_id);
CREATE INDEX school_cleaner_call_called_at_idx
    ON pdl_api.school_cleaner_call (called_at);


-- -----------------------------------------------------------------------------
-- 3. v_school_input — cleaner workload.
--
-- NOTE: request-body key is `name` (school name string) — PDL's /v5/school/clean
-- takes `name`, same as /v5/company/clean; /v5/location/clean is the outlier at
-- `location`. If PDL ever changes the key, change it here only — no Python change.
-- -----------------------------------------------------------------------------

CREATE VIEW pdl_api.v_school_input AS
SELECT id                                   AS input_list_id,
       '/v5/school/clean'                   AS endpoint,
       jsonb_build_object('name', raw_input) AS request_payload
FROM   pdl_api.school_input_list
WHERE  cleaner_status = 'pending';

COMMENT ON VIEW pdl_api.v_school_input IS
    'Workload for the school cleaner pass — pending inputs only. Same claim '
    'pattern as v_location_input.';
