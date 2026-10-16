-- =============================================================================
-- R__function_project_pdl_deltas.sql — project raw PDL deltas to catalog ledger.
--
-- HAND-AUTHORED Postgres function. Repeatable migration: Flyway re-runs this
-- whenever the file checksum changes. Function body is replaced atomically via
-- CREATE OR REPLACE FUNCTION.
--
-- Spec reference: docs/design/02_pipeline_design.md Section 6 + 11.
-- Invoked by:     processing/s3_ingester (pdl_projection_runner) after the
--                 Ingester finishes loading raw.pdl_*_records for a delivery.
--
-- OPEN QUESTION: this is a pure raw→catalog SQL transformation, which is
-- what dbt is built for. Reimplementing this
-- as four dbt incremental models (pdl_id_aliases, pdl_inactive_deleted,
-- pdl_inactive_opted_out, merge_events) targeting the Flyway-shaped catalog
-- tables would give us dbt-native lineage, tests, and selective rebuilds —
-- and collapse the orchestration from "Ingester → projection function →
-- dbt build" to just "Ingester → dbt build". Kept as a Postgres function
-- here for now; moving it to dbt is a possible future refinement.
--
-- Contract: "given a delivery_date, project the rows currently in the raw
-- PDL delta tables into catalog ledger entries: id aliases, deactivation
-- events, and merge audit. Idempotent on re-run for the same delivery_date."
--
-- Inputs (raw delta tables, populated by the Ingester for the current delivery):
--   - raw.pdl_merged_records:    payload {"id": "<old>", "merged_to": "<new>"}
--   - raw.pdl_deleted_records:   payload {"id": "<pdl_id>"}
--   - raw.pdl_opted_out_records: payload {"id": "<pdl_id>"}  (may be empty)
--
-- Outputs (catalog ledger tables):
--   - catalog.pdl_id_aliases:  one row per merge (PK old_pdl_id; ON CONFLICT)
--   - catalog.pdl_inactive:    one row per deactivation (PK pdl_id+observed_at)
--   - catalog.merge_events:    one audit row per pdl_merge (NOT EXISTS dedup)
--
-- observed_at for all rows = delivery_date::timestamptz (midnight UTC).
-- This anchors all events from one delivery to the same instant, so re-runs
-- for the same delivery_date hit predictable PK / NOT EXISTS conflicts.
--
-- Returns jsonb summary with row counts per destination. RAISE on any error
-- (caller transaction rolls back; partial projections never persist).
-- =============================================================================

CREATE OR REPLACE FUNCTION raw.project_pdl_deltas(
    delivery_date  date
) RETURNS jsonb
LANGUAGE plpgsql
AS $func$
DECLARE
    v_observed_at        timestamptz := delivery_date::timestamptz;
    v_aliases_inserted   bigint;
    v_inactive_deleted   bigint;
    v_inactive_opted_out bigint;
    v_merge_events       bigint;
BEGIN
    -- 1. Merges → pdl_id_aliases. PK (old_pdl_id) makes this idempotent.
    INSERT INTO catalog.pdl_id_aliases (old_pdl_id, current_pdl_id, observed_at, delivery_date)
    SELECT
        payload->>'id',
        payload->>'merged_to',
        v_observed_at,
        delivery_date
    FROM raw.pdl_merged_records
    ON CONFLICT (old_pdl_id) DO NOTHING;
    GET DIAGNOSTICS v_aliases_inserted = ROW_COUNT;

    -- 2. Deletions → pdl_inactive. PK (pdl_id, observed_at) handles re-runs.
    INSERT INTO catalog.pdl_inactive (pdl_id, reason, observed_at, delivery_date)
    SELECT
        payload->>'id',
        'deleted',
        v_observed_at,
        delivery_date
    FROM raw.pdl_deleted_records
    ON CONFLICT (pdl_id, observed_at) DO NOTHING;
    GET DIAGNOSTICS v_inactive_deleted = ROW_COUNT;

    -- 3. Opt-outs → pdl_inactive. Same dedup key.
    INSERT INTO catalog.pdl_inactive (pdl_id, reason, observed_at, delivery_date)
    SELECT
        payload->>'id',
        'opted_out',
        v_observed_at,
        delivery_date
    FROM raw.pdl_opted_out_records
    ON CONFLICT (pdl_id, observed_at) DO NOTHING;
    GET DIAGNOSTICS v_inactive_opted_out = ROW_COUNT;

    -- 4. Merges → merge_events (audit log). No PK / unique constraint to
    --    ON CONFLICT against, so we dedup with NOT EXISTS keyed by
    --    (event_type, losing_id, winning_id, observed_at) — same delivery
    --    on re-run produces zero new rows.
    INSERT INTO catalog.merge_events (event_type, losing_id, winning_id, observed_at)
    SELECT
        'pdl_merge',
        r.payload->>'id',
        r.payload->>'merged_to',
        v_observed_at
    FROM raw.pdl_merged_records r
    WHERE NOT EXISTS (
        SELECT 1 FROM catalog.merge_events e
        WHERE e.event_type  = 'pdl_merge'
          AND e.losing_id   = r.payload->>'id'
          AND e.winning_id  = r.payload->>'merged_to'
          AND e.observed_at = v_observed_at
    );
    GET DIAGNOSTICS v_merge_events = ROW_COUNT;

    RETURN jsonb_build_object(
        'delivery_date',           delivery_date,
        'observed_at',             v_observed_at,
        'pdl_id_aliases_inserted', v_aliases_inserted,
        'pdl_inactive_deleted',    v_inactive_deleted,
        'pdl_inactive_opted_out',  v_inactive_opted_out,
        'merge_events_inserted',   v_merge_events
    );
END;
$func$;

COMMENT ON FUNCTION raw.project_pdl_deltas(date) IS
    'Project raw PDL delta tables into the catalog ledger (pdl_id_aliases, pdl_inactive, merge_events) for the given delivery_date. Idempotent on re-run. Atomic in caller transaction. See docs/design/02_pipeline_design.md Section 6 + 11.';
