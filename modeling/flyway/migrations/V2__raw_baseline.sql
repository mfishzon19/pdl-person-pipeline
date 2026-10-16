-- =============================================================================
-- V2__raw_baseline.sql — raw landing tables (parents only; leaves created lazily).
--
-- HAND-AUTHORED. Once the scaffolding compiler (modeling/scaffolding/) is
-- implemented, this file will be regenerated from modeling/dbml/raw.dbml
-- and hand-edits will be overwritten by the generator.
--
-- Partitioning model (per design Section 5):
--   - 1:1 with source files (one leaf per source file)
--   - PDL: PARTITION BY LIST (partition_id smallint)  [file index 0..N]
--   - Lazy leaf creation: this migration creates ONLY parent partitioned tables.
--     Leaves are created on-demand by the Python Ingester (in the same
--     transaction as the COPY) via
--     CREATE TABLE IF NOT EXISTS ... PARTITION OF ... FOR VALUES IN (...).
--
-- Spec reference: docs/design/02_pipeline_design.md Section 5.
-- DBML source:    modeling/dbml/raw.dbml.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS raw;

-- -----------------------------------------------------------------------------
-- PDL content (1 table) — full monthly snapshot
-- -----------------------------------------------------------------------------

CREATE TABLE raw.pdl_person (
    partition_id smallint    NOT NULL,
    payload      jsonb       NOT NULL,
    loaded_at    timestamptz NOT NULL DEFAULT now()
) PARTITION BY LIST (partition_id);

COMMENT ON TABLE raw.pdl_person IS
    'PDL full snapshot. One leaf per part file of the monthly delivery (hundreds of files). Partitioned by partition_id (file index 0..N). Latest-only: each new delivery TRUNCATEs each leaf and re-COPYs.';

-- -----------------------------------------------------------------------------
-- PDL deltas (3 tables) — small per-record delta files; projected to catalog ledger
--
-- File format: PDL ships JSONL (one JSON object per line, gzipped) despite
-- .csv.gz / .gz extensions. The Ingester gunzips each file (detected by the
-- .gz suffix or the object's Content-Encoding header) and COPYs it as a
-- single-column "CSV" (delimiter + quote set to bytes JSON can't contain),
-- landing each line straight into the payload jsonb column. The Ingester is
-- a plain COPY — no per-source parsing.
-- -----------------------------------------------------------------------------

CREATE TABLE raw.pdl_merged_records (
    partition_id smallint    NOT NULL,
    payload      jsonb       NOT NULL,
    loaded_at    timestamptz NOT NULL DEFAULT now()
) PARTITION BY LIST (partition_id);

COMMENT ON TABLE raw.pdl_merged_records IS
    'PDL MERGED_RECORDS delta. Each row payload: {"id": "<old>", "merged_to": "<new>"}. Projected to catalog.pdl_id_aliases + catalog.merge_events by R__function_project_pdl_deltas.sql.';


CREATE TABLE raw.pdl_deleted_records (
    partition_id smallint    NOT NULL,
    payload      jsonb       NOT NULL,
    loaded_at    timestamptz NOT NULL DEFAULT now()
) PARTITION BY LIST (partition_id);

COMMENT ON TABLE raw.pdl_deleted_records IS
    'PDL DELETED_RECORDS delta. Each row payload: {"id": "<pdl_id>"}. Projected to catalog.pdl_inactive (reason=deleted) by R__function_project_pdl_deltas.sql.';


CREATE TABLE raw.pdl_opted_out_records (
    partition_id smallint    NOT NULL,
    payload      jsonb       NOT NULL,
    loaded_at    timestamptz NOT NULL DEFAULT now()
) PARTITION BY LIST (partition_id);

COMMENT ON TABLE raw.pdl_opted_out_records IS
    'PDL OPTED_OUT_RECORDS delta (may be absent entirely; see OQ-3a in docs/requirements/01_pipeline_requirements.md). Each row payload: {"id": "<pdl_id>"}. Projected to catalog.pdl_inactive (reason=opted_out).';
