# Architecture Decision Records

This directory holds **ADRs** — short documents capturing one architectural decision each. Each ADR records *why* a choice was made so future readers don't have to re-derive the reasoning from code or memory.

## Why ADRs (vs design docs, READMEs, code comments)

- **ADR** — one decision, its context, its consequences. **Immutable** once accepted; superseded by a new ADR rather than edited.
- **Design doc / RFC** (e.g. [`../design/02_pipeline_design.md`](../design/02_pipeline_design.md)) — describes how a system *works now*. Living reference, continuously updated.
- **README** — how to *use* a thing.
- **Code comments** — local why-not-what, tied to specific code.

ADRs are for decisions whose reasoning needs to survive past the conversation: "DBML owns shape," "no FKs in staging," "Pattern 1 for staging perf." Design docs describe the resulting system; ADRs explain the *why* behind it.

## Format

Every ADR follows the same shape (Michael Nygard's canonical template):

```markdown
# ADR-NNNN: <short imperative title>

## Context
What forced a decision. Constraints in play. Just enough to make the
rest readable — not the full history.

## Decision
What we chose. One sentence ideally, then specifics.

## Consequences
What this locks us into. Tradeoffs accepted. What becomes harder.
What becomes easier.

## Alternatives considered
What we looked at and rejected, and why. Saves the next reader from
re-walking the same paths.
```

## Authoring

1. Find the next free number (`ls docs/decisions/ | sort -n`)
2. Create `NNNN-short-kebab-title.md`
3. Use the template above
4. Review it alongside the change it describes
5. If it replaces an earlier ADR, add a one-line "Superseded by" note under the old ADR's title

Keep each ADR short — ~1-2 pages is the target. If you're writing 5 pages, you're probably mixing decisions; split.

## Current ADRs

| # | Title |
|---|---|
| [0001](0001-dbml-owns-table-shape-across-layers.md) | DBML owns table shape across raw / staging / integration |
| [0002](0002-fk-enforcement-at-integration-only.md) | FK enforcement at integration layer only |
| [0003](0003-staging-bulk-load-pattern-1.md) | Staging bulk-load via Pattern 1 (post-hook drop / recreate of indexes) |
| [0004](0004-integration-constraint-pattern-2.md) | Integration constraints via Pattern 2 (custom materialization) — superseded by 0009, never implemented |
| [0005](0005-ref-population-layer.md) | Ref tables are populated by their own dedicated dbt layer |
| [0006](0006-location-canonicalization-deferred.md) | Location canonicalization deferred |
| [0007](0007-integration-current-state-ledger-history.md) | Integration tables hold current state only; ledger holds history |
| [0008](0008-dbt-computed-ref-surrogate-ids.md) | Ref-table surrogate IDs + timestamps are dbt-computed, not Postgres-generated |
| [0009](0009-fk-constraint-drop-recreate-for-rebuild.md) | Drop and recreate FK constraints around stateless rebuild ("Pattern 2 for FK") |
| [0010](0010-extend-dbt-computed-surrogate-ids-to-integration.md) | Extend dbt-computed surrogate IDs from `ref.*` to `integration.*` |
| [0011](0011-loader-discovered-ref-tables.md) | Ref tables stay loader-discovered (no seeded layer) |
