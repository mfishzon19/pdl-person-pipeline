-- =============================================================================
-- V15 — Catalog tracking table for ADR-0009 (Pattern 2 FK drop/recreate)
--
-- Holds FK constraint definitions captured before drop by the `drop_fks`
-- dbt macro; consumed by `recreate_fks` after a dbt rebuild completes.
-- Persists across dbt sessions because on-run-start and on-run-end execute
-- in different sessions from individual model builds — temp tables don't
-- span sessions, so a real table is required.
--
-- Underscore-prefixed (`_dropped_fks`) to signal internal/private pipeline
-- state, not consumer-facing. No FK constraints; no indexes beyond PK
-- (table holds at most ~60 rows during any rebuild).
--
-- Recovery story (per ADR-0009 Risks section): if a dbt run aborts between
-- drop_fks (on-run-start) and recreate_fks (on-run-end), this table retains
-- the captured FK definitions. The next dbt run's drop_fks sees the table
-- non-empty, skips the capture step, and lets recreate_fks at on-run-end
-- replay the original definitions. Self-healing without operator action.
-- =============================================================================

CREATE TABLE catalog._dropped_fks (
  conname         text        NOT NULL,
  table_name      text        NOT NULL,
  constraint_def  text        NOT NULL,
  dropped_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conname, table_name)
);

COMMENT ON TABLE catalog._dropped_fks IS
  'ADR-0009 Pattern 2 state: FK constraint definitions captured before drop, '
  'used to recreate after dbt rebuild completes. Persists across dbt sessions. '
  'See docs/decisions/0009-fk-constraint-drop-recreate-for-rebuild.md.';
