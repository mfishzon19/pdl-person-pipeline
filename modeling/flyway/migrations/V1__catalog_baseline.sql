-- =============================================================================
-- V1__catalog_baseline.sql — catalog schema baseline (identity ledger + observability).
--
-- HAND-AUTHORED. Once the scaffolding compiler (modeling/scaffolding/) is
-- implemented, this file will be regenerated from modeling/dbml/catalog.dbml
-- and hand-edits will be overwritten by the generator.
--
-- Spec reference: docs/design/02_pipeline_design.md §9 (identity ledger tables).
-- DBML source:    modeling/dbml/catalog.dbml.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS catalog;

-- -----------------------------------------------------------------------------
-- Identity ledger (4 tables)
-- -----------------------------------------------------------------------------

CREATE TABLE catalog.pdl_id_aliases (
    old_pdl_id     text        NOT NULL,
    current_pdl_id text        NOT NULL,
    observed_at    timestamptz NOT NULL,
    delivery_date  date        NOT NULL,
    PRIMARY KEY (old_pdl_id)
);
CREATE INDEX idx_pdl_id_aliases_current ON catalog.pdl_id_aliases (current_pdl_id);
COMMENT ON TABLE catalog.pdl_id_aliases IS
    'PDL-internal merge mappings: old_pdl_id -> current_pdl_id. Append-only. Populated from MERGED_RECORDS folder.';


CREATE TABLE catalog.pdl_inactive (
    pdl_id        text        NOT NULL,
    reason        text        NOT NULL,
    observed_at   timestamptz NOT NULL,
    delivery_date date        NOT NULL,
    PRIMARY KEY (pdl_id, observed_at),
    CONSTRAINT pdl_inactive_reason_chk
        CHECK (reason IN ('deleted', 'opted_out', 'reactivated'))
);
CREATE INDEX idx_pdl_inactive_pdl_id ON catalog.pdl_inactive (pdl_id);
COMMENT ON TABLE catalog.pdl_inactive IS
    'Append-only audit log of PDL deactivation events (reason ''reactivated'' is reserved; reactivation detection is not implemented).';


CREATE TABLE catalog.person_key_map (
    internal_person_id bigserial   PRIMARY KEY,
    identity_signature text        NOT NULL UNIQUE,
    status             text        NOT NULL,
    merged_into_id     bigint      REFERENCES catalog.person_key_map(internal_person_id),
    first_seen_at      timestamptz NOT NULL,
    last_seen_at       timestamptz NOT NULL,
    CONSTRAINT person_key_map_status_chk
        CHECK (status IN ('active', 'inactive', 'merged_into')),
    CONSTRAINT person_key_map_merged_consistency_chk
        CHECK (
            (status = 'merged_into' AND merged_into_id IS NOT NULL) OR
            (status <> 'merged_into' AND merged_into_id IS NULL)
        )
);
CREATE INDEX idx_person_key_map_status      ON catalog.person_key_map (status);
CREATE INDEX idx_person_key_map_merged_into ON catalog.person_key_map (merged_into_id);
COMMENT ON TABLE catalog.person_key_map IS
    'Stable internal_person_id per identity_signature. Reserved — not populated yet (identity resolution is deferred). Once populated, cannot be reconstructed from the S3 archive if lost.';


CREATE TABLE catalog.merge_events (
    event_id    bigserial   PRIMARY KEY,
    event_type  text        NOT NULL,
    losing_id   text        NOT NULL,
    winning_id  text        NOT NULL,
    observed_at timestamptz NOT NULL,
    notes       text,
    CONSTRAINT merge_events_event_type_chk
        CHECK (event_type IN ('pdl_merge', 'identity_resolution_merge', 'manual_merge'))
);
CREATE INDEX idx_merge_events_losing   ON catalog.merge_events (losing_id);
CREATE INDEX idx_merge_events_winning  ON catalog.merge_events (winning_id);
CREATE INDEX idx_merge_events_observed ON catalog.merge_events (observed_at);
COMMENT ON TABLE catalog.merge_events IS
    'Append-only audit log of all merges (PDL-internal, identity-resolution, manual).';


-- -----------------------------------------------------------------------------
-- Delivery state
-- -----------------------------------------------------------------------------

CREATE TABLE catalog.pdl_delivery (
    delivery_date         date        PRIMARY KEY,
    pdl_dataset_id        text        NOT NULL,
    complete_md_seen_at   timestamptz NOT NULL,
    file_counts           jsonb,
    row_counts            jsonb,
    status                text        NOT NULL,
    started_at            timestamptz,
    completed_at          timestamptz,
    error_message         text,
    pdl_merge_event_count int,
    pdl_deleted_count     int,
    pdl_opted_out_count   int,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pdl_delivery_status_chk
        CHECK (status IN ('received', 'processing', 'success', 'failed'))
);
COMMENT ON TABLE catalog.pdl_delivery IS
    'One row per PDL delivery. Operational visibility under stateless content rebuild.';


-- -----------------------------------------------------------------------------
-- Pipeline run tracking.
-- One pipeline_run per pipeline execution (local CLI invocation).
-- -----------------------------------------------------------------------------

CREATE TABLE catalog.pipeline_run (
    pipeline_run_id     uuid        PRIMARY KEY DEFAULT gen_random_uuid(),  -- DB-assigned unless the caller mints one
    pipeline_name       text        NOT NULL,                     -- e.g. 'pdl_full_load'
    pipeline_version    text        NOT NULL,
    parameters          jsonb,                                    -- pipeline-specific args
    status              text        NOT NULL,                     -- 'running' | 'succeeded' | 'failed' | 'cancelled'
    started_at          timestamptz NOT NULL,
    ended_at            timestamptz,
    duration_ms         bigint      GENERATED ALWAYS AS
                            ((EXTRACT(EPOCH FROM (ended_at - started_at)) * 1000)::bigint) STORED,
    -- ETL-meaningful failure info
    failed_state_name   text,                                     -- which step caused the failure
    semantic_error      text,                                     -- short ETL-meaningful summary
    -- Bookkeeping
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pipeline_run_status_chk
        CHECK (status IN ('running', 'succeeded', 'failed', 'cancelled'))
);
CREATE INDEX idx_pipeline_run_name_started ON catalog.pipeline_run (pipeline_name, started_at DESC);
CREATE INDEX idx_pipeline_run_status_running ON catalog.pipeline_run (status) WHERE status = 'running';
COMMENT ON TABLE catalog.pipeline_run IS
    'One row per pipeline execution. Universal across all workflow types.';


-- -----------------------------------------------------------------------------
-- Ingestion-specific tracking.
-- ingestion_run links to pipeline_run; ingestion_file links to ingestion_run.
-- Cover per-(source, delivery) and per-file detail with source vs
-- destination row-count validation.
-- -----------------------------------------------------------------------------

CREATE TABLE catalog.ingestion_run (
    ingestion_run_id  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    pipeline_run_id   uuid        NOT NULL REFERENCES catalog.pipeline_run(pipeline_run_id),
    source_name       text        NOT NULL,                       -- e.g. 'pdl_person'
    delivery_date     date        NOT NULL,
    sub_key           jsonb,                                      -- per-source sub-id
    status            text        NOT NULL,                       -- 'started' | 'success' | 'failed'
    started_at        timestamptz NOT NULL,
    ended_at          timestamptz,
    duration_seconds  numeric,
    total_file_count  int,                                        -- total files in this delivery
    total_row_count   bigint,                                     -- sum of ingestion_file.row_count
    total_bytes       bigint,                                     -- sum of ingestion_file.size_bytes
    error_message     text,
    CONSTRAINT ingestion_run_status_chk
        CHECK (status IN ('started', 'success', 'failed'))
);
CREATE INDEX idx_ingestion_run_pipeline ON catalog.ingestion_run (pipeline_run_id);
CREATE INDEX idx_ingestion_run_source_delivery ON catalog.ingestion_run (source_name, delivery_date);
COMMENT ON TABLE catalog.ingestion_run IS
    'One row per (source, delivery) ingestion. FK to pipeline_run. Aggregates totals from ingestion_file. One Ingester process per delivery; intra-process concurrency loads multiple files in parallel from the single process.';


CREATE TABLE catalog.ingestion_file (
    ingestion_file_id   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    ingestion_run_id    uuid        NOT NULL REFERENCES catalog.ingestion_run(ingestion_run_id),
    s3_key              text        NOT NULL,
    target_table        text        NOT NULL,                     -- e.g. 'raw.pdl_person'
    partition_value     text        NOT NULL,                     -- partition value used (Python casts to partition column type when building leaf DDL)
    expected_row_count  bigint,                                   -- source-side count
    row_count           bigint,                                   -- destination-side count (COUNT(*) on leaf)
    size_bytes          bigint,
    status              text        NOT NULL,                     -- 'pending' | 'loading' | 'success' | 'failed'
    load_started_at     timestamptz,
    load_ended_at       timestamptz,
    error_message       text,
    CONSTRAINT ingestion_file_status_chk
        CHECK (status IN ('pending', 'loading', 'success', 'failed')),
    CONSTRAINT ingestion_file_unique_key
        UNIQUE (ingestion_run_id, s3_key)
);
CREATE INDEX idx_ingestion_file_run    ON catalog.ingestion_file (ingestion_run_id);
CREATE INDEX idx_ingestion_file_status ON catalog.ingestion_file (status) WHERE status IN ('pending', 'failed');
COMMENT ON TABLE catalog.ingestion_file IS
    'One row per file in the delivery. Records source-side (expected_row_count) and destination-side (row_count) for validation. Finder INSERTs status=pending; Ingester UPDATEs status to terminal + row counts. The runner queries this to decide pipeline_run terminal status.';
