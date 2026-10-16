# ADR-0009: Drop and recreate FK constraints around stateless rebuild ("Pattern 2 for FK")

## Context

`ref.*` and `integration.*` dbt models materialize via `incremental + append` with a `TRUNCATE TABLE {{ this }} RESTART IDENTITY CASCADE` pre-hook (the "stateless content rebuild" pattern — see ADR-0001 background and `dbt_project.yml`). The `CASCADE` clause recursively acquires `AccessExclusiveLock` on every table that holds a foreign-key reference to the target. With dbt's default multi-thread execution (`--threads 4`), two concurrent model rebuilds can grab CASCADE-acquired locks in conflicting order, producing a Postgres deadlock.

This was first observed during ref-layer validation: `dbt build --select path:models/ref --threads 4` lost some ref models to deadlock errors, and only `--threads 1` avoided it. The risk scales with the FK constraint count: as integration models land and ref FKs accumulate, the deadlock probability under concurrent rebuilds grows.

FK constraint surface when this was decided (after V14):

| Source schema → Target schema | FK count |
|---|---:|
| `ref → ref` | 12 |
| `integration → integration` | 26 |
| `integration → ref` | 21 |
| **Total relevant** | **59** |

`catalog → catalog` FKs (9) are intra-ledger and unaffected by the stateless content rebuild (catalog is append-only stateful state per ADR-0001).

## Decision

**Drop all FK constraints in `ref` and `integration` before any rebuild begins; recreate them after the rebuild completes.** "Pattern 2 for FK constraints" — extension of ADR-0003's "drop/recreate indexes around bulk INSERT" pattern, applied across schemas.

**Implementation**: dbt `on-run-start` and `on-run-end` project-level hooks invoke macros that query `pg_catalog` for current FK constraints in `ref` + `integration` schemas, persist their definitions, drop them, then recreate from the persisted definitions.

**Concretely:**

```yaml
# dbt_project.yml
on-run-start:
  - "{{ drop_fks(['ref', 'integration']) }}"
on-run-end:
  - "{{ recreate_fks() }}"
```

- `drop_fks` queries `pg_constraint` for `contype = 'f'` in the target schemas, stores `(conname, table_name, constraint_def)` in `catalog._dropped_fks`, and drops each constraint. If the tracking table already has rows (a previous run aborted mid-flight), it skips the capture and leaves them for `recreate_fks`.
- `recreate_fks` reads `catalog._dropped_fks`, re-adds each constraint `NOT VALID` (Postgres registers it but skips the row-by-row validation scan), and truncates the tracking table.

**Why `NOT VALID` rather than default-VALID:** the integration + ref schemas are **rebuilt every cycle and have no live INSERTs between rebuilds**. Postgres's row-by-row validation at recreate time would scan millions of rows to verify constraints that are then dropped again before the NEXT rebuild's INSERTs. The validation runs once per rebuild boundary but catches nothing the dbt `relationships` tests (in `schema.yml`) wouldn't already catch at the same boundary. Net result: `NOT VALID` skips the redundant work; dbt tests do the actual integrity check. The FK constraints in `pg_catalog` retain their documentation value (visible in `\d` output, ER-diagram tools) without paying the validation cost. See the "Consequences" and "Alternatives considered" sections below for the full justification.

Catalog table (not temp): persistent because dbt's on-run-start runs in a different session from individual model builds, and temp tables don't span sessions. The persistent tracking table also enables recovery if a rebuild aborts mid-flight (next run reads the table, recreates the FKs that were dropped, then continues).

### What this enables

- **Multi-thread dbt rebuilds** without deadlock — concurrent TRUNCATEs no longer cascade-lock other tables; FKs simply don't exist during the rebuild.
- **Predictable wall-clock** — the `--threads 1` workaround serialized every ref and integration model. With FKs dropped, `--threads 4` parallelism is safe.
- **Future-proof** — new integration tables, a future warehouse layer, or an additional source would add more FK references; this pattern scales.

## Consequences

**Benefits:**

- Eliminates the deadlock class entirely (no CASCADE locks during rebuild).
- Restores dbt's default `--threads 4` (or higher) concurrency.
- Self-documenting: macros query `pg_catalog` rather than maintaining a hardcoded constraint list. Future schema changes (new FK constraints) are automatically handled without macro changes.
- Implementation is centralized (two macros + one yaml hook block); no per-model boilerplate.

**Costs:**

- **Integrity check moves from Postgres to dbt** (the **architectural trade-off** of this ADR). With `NOT VALID`, the FK constraints exist as metadata but are not retroactively checked against existing rows. The real orphan-row detection happens in dbt's `relationships` tests at the `dbt build` step. Acceptable for our stateless-rebuild architecture because:
  1. There are no live INSERTs into integration between rebuilds — Postgres-level "always-on" enforcement protects against nothing.
  2. `dbt build` runs tests AFTER models materialize; a failed `relationships` test fails the build at the same logical moment a failed `VALIDATE` would.
  3. The `schema.yml` tests are declarative, versioned in code, and easier to filter / customize than Postgres constraint definitions.
- **Mid-rebuild data integrity is unenforced.** Between `on-run-start` (FKs dropped) and `on-run-end` (FKs recreated), no FK enforcement exists. If dbt aborts mid-rebuild AND someone queries integration during that window, they could read FK-violating data. Mitigation: stateless rebuild semantics already mean "current truth is whatever's in the tables right now"; consumers know to query only after a successful pipeline run.
- **Implementation surface**: two short Jinja macros + a tracking-table migration (V15). One-time cost; maintenance is near-zero (the macros self-discover FKs via `pg_catalog`).
- **on-run-start runs even for `dbt test` or `dbt seed`.** The drop + recreate is cheap on its own, so the hooks run unconditionally; making them no-op for invocations that don't rebuild ref / integration is possible but not done.
- **Protection against ad-hoc manual DB edits is reduced**. With `NOT VALID`, a manually-INSERTed row that violates a FK still fails (the constraint applies to new inserts even when `NOT VALID`). But existing rows aren't verified, so cumulative manual-edit drift is harder to detect. Mitigation: don't make ad-hoc edits; if someone must, run an explicit `VALIDATE CONSTRAINT` after.

**Risks:**

- **Aborted rebuild leaves FKs missing**. Mitigated by the persistent tracking table — next run's on-run-start sees the tracking table populated, skips the capture step, and on-run-end recreates from those rows. The macros log the drop / recreate counts as NOTICEs, so a mismatch is visible in the dbt log.
- **`pg_catalog` query semantics may change between Postgres versions**. The local stack runs Postgres 18; the `pg_constraint` table shape has been stable for years. Low risk.
- **Schema.yml `relationships` tests must actually exist** on every FK column. If a `relationships` test is missing on column X but the FK constraint X → Y was dropped+recreated as NOT VALID, that FK's enforcement gap goes uncaught. Mitigation: an audit that diffs `pg_constraint` FKs against `schema.yml` `relationships` tests (not built; see Revisit triggers).

### Future compatibility with user corrections

A possible future capability is **user corrections** — small per-record edits submitted by a downstream application. The cleanest pattern is to store corrections in a separate stateful schema (`user_corrections.*` or similar) and **treat them as another data source** that flows into `integration.*` during the next rebuild — the same shape as PDL data today.

Under that pattern, this ADR's design **continues to work without changes**:

- `integration.*` stays stateless rebuild. User corrections live in their own schema; durability is handled by that schema's own storage, not by `integration.*` persistence.
- FK enforcement for corrections happens the same way as for other sources: dbt's `relationships` tests during the rebuild's test phase. Bad correction → test fails → operator notified.
- No special-case handling needed for the NOT VALID FK constraints. They're agnostic to which source produced each row.

If the design ever shifts to **direct live writes into `integration.*` from an application** (not the chosen pattern, but worth flagging), the trade-off changes: live writes would need Postgres-level FK enforcement, which means `VALIDATE`-ing the constraints. At that point, reopen this ADR.

## Alternatives considered

**A. Keep `--threads 1` permanently.**
The interim workaround. Avoids deadlocks by avoiding concurrency.
- *Rejected* because: doesn't scale. Each delivery's rebuild takes serial time; integration model count keeps growing. Total rebuild wall-clock becomes the bottleneck. Loses dbt's primary perf lever (concurrency).

**B. `DELETE FROM` instead of `TRUNCATE ... CASCADE`.**
No CASCADE locks because no FK propagation. Each table's row count goes to 0 individually.
- *Rejected* because: (i) slow on large tables — DELETE is per-row with WAL writes vs TRUNCATE's metadata-only operation; (ii) doesn't reset IDENTITY sequences (the dbt incremental pattern expects identity reset via `RESTART IDENTITY`); (iii) leaves index bloat that VACUUM later cleans up. Net slower than Pattern 2.

**C. `DEFERRABLE` FK constraints + `SET CONSTRAINTS ALL DEFERRED` in a single transaction.**
Postgres can defer constraint checks to commit time. Pattern would be: wrap entire dbt run in one transaction; SET CONSTRAINTS DEFERRED; constraints checked at commit.
- *Rejected* because: (i) dbt's incremental materialization runs each model in its own transaction (commit between models). Cross-model constraint deferral doesn't work without re-architecting dbt's transaction handling. (ii) Requires changing all 59 FKs to DEFERRABLE (one-time DDL). (iii) Single big transaction across a multi-hour rebuild has its own problems (lock retention, WAL growth).

**D. Drop FKs at the DBML level entirely (no FK constraints in the database).**
Move FK enforcement to dbt tests instead of Postgres constraints.
- *Rejected* because: loses real-time integrity enforcement. Bugs in dbt models could silently produce orphan rows. ADR-0002 already establishes FK enforcement at integration layer; this would walk that back.

**E. Per-model `pre_hook` drops the SPECIFIC FKs targeting that table.**
Instead of global drop, each model drops only the FKs that target itself.
- *Rejected* because: (i) doesn't avoid deadlocks — a multi-thread run still has thread A dropping FKs on `ref.industry` while thread B is dropping FKs on `ref.country`, with cross-references between them. Per-model drops still collide. (ii) Significantly more per-model boilerplate vs centralized hooks. (iii) Harder to verify completeness — easy to miss a FK that points at the table.

**F. Drop and recreate `ref` + `integration` schemas entirely on each rebuild.**
Conceptually simpler: `DROP SCHEMA ref CASCADE`, `DROP SCHEMA integration CASCADE`, re-run all Flyway DDL to recreate empty tables + constraints, then repopulate with dbt. No FK constraint management at all; no tracking table; no macros.
- *Rejected* because:
  - **Violates ADR-0001** (Flyway owns DDL; one-time-apply model). Flyway tracks history in `catalog.flyway_schema_history`; running migrations twice on the same DB normally errors. Would require either a "rebuild mode" for Flyway, dbt-managed schema creation (contradicts ADR-0001), or new pre-rebuild orchestration. Bigger architectural change than Pattern 2.
  - **Re-grants needed** — `DROP SCHEMA` wipes permissions; `R__permissions.sql` would have to re-run as part of every rebuild orchestration.
  - **Partial-failure recovery is worse** — DROP succeeds, CREATE fails → schemas missing → consumer-facing errors. With Pattern 2, partial failures leave most of the schema intact.
- **Worth revisiting** alongside the Flyway base cleanup (collapse V1..V_n into one-file-per-schema). Both involve restructuring Flyway's role; if that cleanup is ever taken on, evaluating drop/recreate schemas at the same time may make sense as a single coordinated change.

## Implementation

- `modeling/flyway/migrations/V15__catalog_dropped_fks_tracking.sql` — creates `catalog._dropped_fks (conname, table_name, constraint_def, dropped_at)`.
- `processing/dbt/macros/hooks/drop_fks.sql` — capture + drop; idempotent when the tracking table already has rows.
- `processing/dbt/macros/hooks/recreate_fks.sql` — recreate `NOT VALID`; truncate the tracking table.
- `processing/dbt/dbt_project.yml` — the `on-run-start` / `on-run-end` hooks.

Validation: after a `dbt build --threads 4` over ref + integration, `catalog._dropped_fks` is empty and `\d ref.country` shows its FKs back in place marked `NOT VALID`.

## Revisit triggers

- **Design shifts to live writes into `integration.*`** (e.g., user corrections going direct to integration rather than via the separate-source pattern described above). Live writes require Postgres-level FK enforcement, which means `VALIDATE`-ing all constraints. Reopen this ADR to evaluate the cost.
- **PG version upgrade** changes `pg_constraint` shape (low risk; stable for years).
- **A new integration source or table family** adds many new integration→ref FKs. Verify the auto-discovery macro picks them up; verify each new FK has a corresponding `schema.yml` relationships test.
- **`schema.yml` linter / automated check** for missing relationships tests is not implemented — if a new FK lands without a corresponding test, NOT VALID enforcement silently has a gap. Once the linter exists, this risk is mitigated.
- **Flyway base cleanup decision** — if the schema-restructure work is taken on, evaluate alternative F (drop/recreate schemas) at the same time.

## References

- [ADR-0001](0001-dbml-owns-table-shape-across-layers.md) — DBML as source of truth (this ADR doesn't change schema definitions; FKs in DBML stay; only their runtime presence during rebuild changes)
- [ADR-0002](0002-fk-enforcement-at-integration-only.md) — FK enforcement architecture (this ADR temporarily relaxes that during rebuild only)
- [ADR-0003](0003-staging-bulk-load-pattern-1.md) — Pattern 1 (index drop/recreate per model). Pattern 2 is the cross-schema generalization.
- [ADR-0004](0004-integration-constraint-pattern-2.md) — the earlier, never-implemented plan for integration constraints (a custom `constraint` materialization). Superseded by this ADR.
- `modeling/dbml/integration.dbml`, `modeling/dbml/ref.dbml` — FK definitions in DBML
- `modeling/flyway/migrations/V4__ref_baseline.sql`, `V6__integration_baseline.sql` — FK constraints created
- `processing/dbt/dbt_project.yml` — the `on-run-start` / `on-run-end` hooks
