-- =============================================================================
-- V3__pdl_api_company_enrichment.sql — pdl_api schema + company-enrichment
-- feature tables (input list + cleaner-call audit + enrichment-call audit) +
-- driver views for the generic PDL API caller.
--
-- HAND-AUTHORED. Generated downstream from modeling/dbml/pdl_api.dbml for
-- the three tables and their indexes. Sequence, CHECK constraints, GENERATED
-- columns, and views are hand-authored additions (DBML cannot express them).
--
-- File scope = one PDL "feature" (company enrichment). Later PDL features
-- ship as their own V<n>__pdl_api_<feature>.sql files (location cleaner in
-- V35, school cleaner in V36).
--
-- Spec reference: docs/design/18_pdl_api_generic_caller.md, sections "Queue
-- tables", "Driver views" and "Audit tables".
--
-- Three tables in the pdl_api schema:
--   pdl_api.company_input_list      — queue (one row per company-on-a-list)
--   pdl_api.company_cleaner_call    — append-only audit of Cleaner calls
--   pdl_api.company_enrichment_call — append-only audit, one row per
--                                     record-in-bulk-batch
--
-- Two views (same column shape, driving one generic caller):
--   pdl_api.v_company_input_for_cleaner    — Cleaner workload
--   pdl_api.v_company_input_for_enrichment — Enrichment workload
--
-- Surrogate keys are `bigint GENERATED ALWAYS AS IDENTITY`. `pdl_company_id`
-- is PDL's external natural key (text) — separate from the bigint PK,
-- carried across all PDL company-data sources.
--
-- Schema creation: pdl_api is auto-created by Flyway via `flyway.schemas`
-- in flyway.conf. The CREATE SCHEMA IF NOT EXISTS below is a
-- belt-and-suspenders no-op for fresh DBs where Flyway happens to run this
-- migration before the schema list is processed.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS pdl_api;

COMMENT ON SCHEMA pdl_api IS
    'Operational state for the generic PDL API caller — per-domain input '
    'lists, queue, audit, and driver views. Canonical destination tables '
    '(company, etc.) live in their own schemas.';

-- -----------------------------------------------------------------------------
-- Shared sequence for grouping per-record audit rows that arrived in the same
-- HTTP bulk call. One nextval() per HTTP request; all per-record rows share
-- the same bulk_batch_id.
-- -----------------------------------------------------------------------------

CREATE SEQUENCE pdl_api.company_enrichment_batch_seq AS bigint;

COMMENT ON SEQUENCE pdl_api.company_enrichment_batch_seq IS
    'Groups per-record audit rows from one HTTP bulk-enrichment call. '
    'Caller takes nextval() before building each batch; all up-to-100 '
    'records share that batch id.';

-- -----------------------------------------------------------------------------
-- 1. company_input_list — queue of companies to clean and/or enrich.
--
-- Same pdl_company_id can appear in multiple rows (same company on two
-- different input lists) — only the first to finish enrichment hits PDL; the
-- enrichment loader marks siblings 'skipped_already_enriched'.
-- -----------------------------------------------------------------------------

CREATE TABLE pdl_api.company_input_list (
    id                  bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_list         text          NOT NULL,
    pdl_search_params   jsonb         NOT NULL,
    passthrough_params  jsonb,
    pdl_company_id      text,
    cleaner_status      text          NOT NULL,
    enrichment_status   text          NOT NULL,
    worker_id           text,
    claimed_at          timestamptz,
    created_at          timestamptz   NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT company_input_list_cleaner_status_check CHECK (
        cleaner_status IN ('pending', 'not_needed', 'in_progress',
                           'resolved', 'not_found', 'error')
    ),
    CONSTRAINT company_input_list_enrichment_status_check CHECK (
        enrichment_status IN ('pending', 'in_progress', 'enriched',
                              'not_found', 'error', 'skipped_already_enriched')
    )
);

COMMENT ON TABLE pdl_api.company_input_list IS
    'Queue + state for company-cleaner and company-enrichment workers. '
    'One row per company-on-a-list; same pdl_company_id may appear in '
    'multiple rows (loader collapses siblings after first enrichment).';

COMMENT ON COLUMN pdl_api.company_input_list.source_list IS
    'Provenance label, e.g. ''example_company_list'', '
    '''pdl_most_frequent_companies'', ''person_derived''.';
COMMENT ON COLUMN pdl_api.company_input_list.pdl_search_params IS
    'PDL API request body for matching: {"name": ..., "website": ...} '
    'when unresolved, or {"id": "<pdl_company_id>"} when pre-resolved. '
    'No URL, host, or auth — caller supplies those.';
COMMENT ON COLUMN pdl_api.company_input_list.passthrough_params IS
    'Caller correlation data — echoed via PDL''s per-record metadata '
    'field. Free-form jsonb.';
COMMENT ON COLUMN pdl_api.company_input_list.pdl_company_id IS
    'Loose reference to integration.company.pdl_company_id (text). NULL '
    'until Cleaner resolves it, or pre-populated when the id is already known. '
    'No FK — destination row may not exist yet when this is set.';
COMMENT ON COLUMN pdl_api.company_input_list.worker_id IS
    'NULL unless currently claimed by a worker. Sweeper resets stale '
    'in_progress rows back to ''pending''.';

-- Indexes (see docs/design/18_pdl_api_generic_caller.md).
CREATE INDEX company_input_list_cleaner_pending_idx
    ON pdl_api.company_input_list (cleaner_status)
    WHERE cleaner_status = 'pending';
CREATE INDEX company_input_list_enrichment_pending_idx
    ON pdl_api.company_input_list (enrichment_status)
    WHERE enrichment_status = 'pending';
CREATE INDEX company_input_list_pdl_company_id_idx
    ON pdl_api.company_input_list (pdl_company_id);
CREATE INDEX company_input_list_source_list_idx
    ON pdl_api.company_input_list (source_list);


-- -----------------------------------------------------------------------------
-- 2. company_cleaner_call — append-only audit of Cleaner API calls.
--
-- Single-record endpoint (not bulk), so one row per HTTP call. Free API but
-- logged for replay + debugging. pdl_company_id is computed by Postgres
-- from response_json so it can never drift.
-- -----------------------------------------------------------------------------

CREATE TABLE pdl_api.company_cleaner_call (
    id              bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    input_list_id   bigint        NOT NULL
                                  REFERENCES pdl_api.company_input_list (id),
    endpoint        text          NOT NULL,
    request_json    jsonb         NOT NULL,
    response_status smallint,
    response_json   jsonb,
    called_at       timestamptz   NOT NULL DEFAULT clock_timestamp(),
    latency_ms      int,
    error_message   text,

    -- Generated: PDL's natural-key response field. STORED so it's indexable
    -- and persists to disk; recomputed if response_json is ever rewritten.
    pdl_company_id  text          GENERATED ALWAYS AS
                                  (response_json->>'id') STORED
);

COMMENT ON TABLE pdl_api.company_cleaner_call IS
    'Append-only audit of every PDL Company Cleaner call. PDL-level '
    '"no match" is response_status=404 (not error_message).';

CREATE INDEX company_cleaner_call_pdl_company_id_idx
    ON pdl_api.company_cleaner_call (pdl_company_id);
CREATE INDEX company_cleaner_call_input_list_id_idx
    ON pdl_api.company_cleaner_call (input_list_id);
CREATE INDEX company_cleaner_call_called_at_idx
    ON pdl_api.company_cleaner_call (called_at);


-- -----------------------------------------------------------------------------
-- 3. company_enrichment_call — append-only audit, one row per
--    record-in-bulk-batch.
--
-- A single HTTP call with 100 records writes 100 rows here, all sharing
-- bulk_batch_id. This granularity matches PDL's per-match billing model
-- while preserving the HTTP-call grouping for replay.
-- -----------------------------------------------------------------------------

CREATE TABLE pdl_api.company_enrichment_call (
    id                   bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bulk_batch_id        bigint        NOT NULL,
    input_list_id        bigint        NOT NULL
                                       REFERENCES pdl_api.company_input_list (id),
    endpoint             text          NOT NULL,
    request_json         jsonb         NOT NULL,
    response_status      smallint,
    response_json        jsonb,
    called_at            timestamptz   NOT NULL DEFAULT clock_timestamp(),
    latency_ms           int,
    error_message        text,

    -- Generated columns extracted from the per-record response slice.
    pdl_company_id       text          GENERATED ALWAYS AS
                                       (response_json->>'id') STORED,
    pdl_dataset_version  text          GENERATED ALWAYS AS
                                       (response_json->>'dataset_version') STORED,
    pdl_likelihood       int           GENERATED ALWAYS AS
                                       ((response_json->>'likelihood')::int) STORED
);

COMMENT ON TABLE pdl_api.company_enrichment_call IS
    'Append-only audit, one row per record returned in a bulk-enrichment '
    'response. bulk_batch_id groups records that shared one HTTP call.';

COMMENT ON COLUMN pdl_api.company_enrichment_call.bulk_batch_id IS
    'Caller takes nextval(pdl_api.company_enrichment_batch_seq) before '
    'building each batch; up to 100 records in the batch share this value.';
COMMENT ON COLUMN pdl_api.company_enrichment_call.called_at IS
    'HTTP call timestamp — same for all rows in the batch.';
COMMENT ON COLUMN pdl_api.company_enrichment_call.latency_ms IS
    'HTTP call latency — same for all rows in the batch.';

CREATE INDEX company_enrichment_call_pdl_company_id_idx
    ON pdl_api.company_enrichment_call (pdl_company_id);
CREATE INDEX company_enrichment_call_bulk_batch_id_idx
    ON pdl_api.company_enrichment_call (bulk_batch_id);
CREATE INDEX company_enrichment_call_input_list_id_idx
    ON pdl_api.company_enrichment_call (input_list_id);
CREATE INDEX company_enrichment_call_called_at_idx
    ON pdl_api.company_enrichment_call (called_at);


-- -----------------------------------------------------------------------------
-- Views — the generic-caller contract (docs/design/18_pdl_api_generic_caller.md). Both views expose the
-- same column shape so one API-caller implementation serves both:
--
--   input_list_id    bigint   row in company_input_list this corresponds to
--   endpoint         text     PDL endpoint to POST to
--   request_payload  jsonb    per-record params block
--   passthrough      jsonb    caller correlation data (echoed via metadata)
-- -----------------------------------------------------------------------------

CREATE VIEW pdl_api.v_company_input_for_cleaner AS
SELECT id                  AS input_list_id,
       '/v5/company/clean' AS endpoint,
       pdl_search_params   AS request_payload,
       passthrough_params  AS passthrough
FROM   pdl_api.company_input_list
WHERE  cleaner_status = 'pending'
  AND  pdl_company_id IS NULL;

COMMENT ON VIEW pdl_api.v_company_input_for_cleaner IS
    'Workload for the Cleaner pass — unresolved inputs only. Worker takes '
    'a batch with FOR UPDATE SKIP LOCKED, marks rows in_progress, calls PDL '
    'Cleaner, writes audit + flips cleaner_status to resolved/not_found.';


-- v_company_input_for_enrichment
--
-- TODO: integration.company (docs/data_model/08_company.md) now exists; a
--       NOT EXISTS clause against integration.company.pdl_company_id WHERE
--       source = 'enrichment' would enforce the "no double enrichment" rule
--       in the view. Today the application layer is responsible for not
--       re-enriching already-enriched pdl_company_ids (siblings are marked
--       'skipped_already_enriched'); this view returns them. Replace with:
--
--           CREATE OR REPLACE VIEW pdl_api.v_company_input_for_enrichment AS
--           SELECT cil.id                                       AS input_list_id,
--                  '/v5/company/enrich/bulk'                    AS endpoint,
--                  jsonb_build_object('id', cil.pdl_company_id) AS request_payload,
--                  cil.passthrough_params                       AS passthrough
--           FROM   pdl_api.company_input_list cil
--           WHERE  cil.enrichment_status = 'pending'
--             AND  cil.pdl_company_id IS NOT NULL
--             AND  NOT EXISTS (
--                    SELECT 1 FROM integration.company c
--                    WHERE c.pdl_company_id = cil.pdl_company_id
--                      AND c.source = 'enrichment'
--                  );

CREATE VIEW pdl_api.v_company_input_for_enrichment AS
SELECT cil.id                                       AS input_list_id,
       '/v5/company/enrich/bulk'                    AS endpoint,
       jsonb_build_object('id', cil.pdl_company_id) AS request_payload,
       cil.passthrough_params                       AS passthrough
FROM   pdl_api.company_input_list cil
WHERE  cil.enrichment_status = 'pending'
  AND  cil.pdl_company_id IS NOT NULL;

COMMENT ON VIEW pdl_api.v_company_input_for_enrichment IS
    'Workload for the Enrichment pass — resolved inputs only. Application '
    'currently must check for already-enriched pdl_company_ids; this could '
    'move into the view as a NOT EXISTS against integration.company (see the '
    'TODO above the CREATE VIEW statement). Once pdl_company_id is known, enrichment is '
    'always by id (one credit, deterministic match).';
