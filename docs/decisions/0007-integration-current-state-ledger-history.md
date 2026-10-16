# ADR-0007: Integration tables hold current state only; ledger holds history

## Context

The architecture has two kinds of layer ([design/02](../design/02_pipeline_design.md), the "stateless content + stateful identity ledger" diagram):

- **Stateless content** — `staging.*`, `integration.*`, `ref.*` — rebuilt in full from current source data on every run.
- **Stateful identity ledger** — `catalog.person_key_map`, `catalog.pdl_inactive`, `catalog.pdl_id_aliases`, `catalog.merge_events` — append-only, preserves identity continuity across deactivation/reactivation/merge events.

For PDL persons, this raises a question: how should `integration.person` represent a PDL person that PDL has deactivated (`deleted/` or `opted_out/` folder)?

Three options were considered:

- **A. Not present** — inactive person absent from `integration.person`; identity preserved only in the ledger.
- **B. Row preserved with `status='inactive'` + NULL attributes** — uniform single query surface on `integration.person`.
- **C. Row preserved with last-known attributes** — supports "what was Jane's title before she was deleted?" queries.

The original deactivation language in requirements/01 and design/02 read like B *("the integration-layer row remains in `integration.person` with `status='inactive'`. Preserves `internal_person_id` and audit trail.")*. That phrasing predates the staging design decisions (DBML, ADR-0001, ADR-0003) and is inconsistent with the stateless-rebuild contract that's now load-bearing across the codebase.

There is no `status` column on `integration.person` in the DBML (`modeling/dbml/integration.dbml`).

## Decision

**Option A.** `integration.person` (and all sibling integration tables — `experience`, `person_education`, `company`, `school`, `person_skill`, `person_interest`, etc.) hold the **current view only**, rebuilt stateless from current source data every run. The **ledger** (`catalog.person_key_map` + `catalog.pdl_inactive` + `catalog.merge_events`) holds the full identity and event history.

**Concretely:**

- When PDL stops shipping a `pdl_id` (it moves to `deleted/` or `opted_out/`), it is no longer in `staging.pdl_person_unique`, so it is no longer in `integration.person` on the next rebuild. **The row disappears.** No filter logic required; this falls out of stateless rebuild for free.
- **No `status` column** on `integration.person`. Anyone in the table is active by construction.
- **No FK or required JOIN** from `integration.person` to `catalog.person_key_map`. The link exists implicitly via `pdl_id`.
- When a `pdl_id` reappears in `data/`, the next integration rebuild includes the person again; no integration logic is involved. Recording that as a reactivation event in the ledger, and keeping a stable `internal_person_id` across the gap via `catalog.person_key_map`, are ledger-side features that are designed but not built (no code writes `reason = 'reactivated'`, and `person_key_map` is not populated; see [design/02 §12](../design/02_pipeline_design.md#12-open-items)).
- The "audit trail" (when, why a person was deactivated/reactivated/merged) lives in `catalog.pdl_inactive` and `catalog.merge_events`. Consumers query the ledger directly.

**Same principle applies to all integration entity tables.** `integration.experience`, `integration.person_education`, `integration.company`, `integration.school`, `integration.company_affiliation`, and all `integration.person_*` / `integration.experience_*` junctions hold current state only. They have no `status` columns and no inactive-handling logic. When the underlying source row drops out, the integration row drops out on the next rebuild.

## Consequences

**Benefits:**

- Clean separation: `integration.*` answers "what is true now?"; `catalog.*` answers "what's happened over time?". Two distinct query surfaces, two distinct mental models.
- No `status` column to add to integration tables; no coupling between content and ledger schemas; no required JOIN from integration to catalog for basic queries.
- A returning person reappears in integration automatically. No special-case logic in dbt models.
- Recovery model in [requirements/01 §12](../requirements/01_pipeline_requirements.md) ("drop and rebuild the affected content layers") continues to work — integration is fully derivable from current source data + ledger.

**Costs we accept:**

- A consumer wanting "everyone we've ever assigned an `internal_person_id` to, plus their last-known attributes" cannot answer that from `integration.person`. They get the identity list from `catalog.person_key_map`; for attributes, they need either a snapshot system (not in scope; point-in-time queries are explicitly out of scope per design/02) or a future warehouse / presentation layer.
- Joins from external tables to `integration.person.id` are inherently "current persons only". This matches expectation but should be documented for warehouse-layer designers.

**Risks:**

- A future warehouse / presentation-layer consumer may want a "person with status" surface for inactive-aware views. Solvable with a `v_person_with_status` view that LEFT JOINs `integration.person` to `catalog.person_key_map`; doesn't change the underlying separation. Not in scope here.

## Alternatives considered

**B. Row preserved with `status='inactive'` + NULL attributes** *(matched the original requirements/01 + design/02 language)*

Would add a `status` column to `integration.person`, populated by joining staging to `catalog.person_key_map`. Active rows get full attributes; inactive rows get NULL attributes.

- *Rejected* because: the only consumer benefit is "single query surface" — but consumers who care about inactive state are necessarily ledger-aware queries anyway. The cost is real: integration tables become coupled to the catalog ledger (must read it as a source), the schema gains a redundant column (id + status duplicates `person_key_map`), and "what is in integration?" becomes ambiguous (current-active OR all-time?).

**C. Row preserved with last-known attributes**

Would require persisting attribute snapshots across rebuilds — a new stateful subsystem outside today's architecture.

- *Rejected* because: violates the stateless content rebuild principle (requirements/01 §2, design/02). Recovery model in requirements/01 §12 explicitly assumes integration is rebuildable from current source data alone. Adding a "last-known attributes" store would also require a retention policy, a privacy-disposal hook, and integration with the ledger — large scope for marginal value.

## Docs aligned with this ADR

The deactivation language in requirements/01 (now §7) and design/02 (which described option B, and used a stale `_conformed` table-name suffix) was rewritten to match this ADR: when PDL no longer ships a `pdl_id`, the next integration rebuild simply omits the person; the ledger (`catalog.person_key_map` + `catalog.pdl_inactive`) preserves identity and the audit trail.

## Revisit triggers

- **Warehouse / presentation-layer design** — if a consumer demands "show inactive persons with last-known attributes," reopen this ADR. Most likely resolved by a warehouse view (LEFT JOIN integration + ledger), not by changing the integration schema.
- **Any consumer surfacing a real need** for inactive-attribute queries against `integration.*`. None is anticipated.

## References

- [requirements/01](../requirements/01_pipeline_requirements.md) §2 (stateless content + stateful identity ledger), §6 (update semantics — no attribute history), §7 (deactivation semantics)
- [design/02](../design/02_pipeline_design.md) (architecture rationale + deactivation language)
- `modeling/dbml/integration.dbml` (rebuild policy header comment — aligned)
- `modeling/dbml/catalog.dbml` — `person_key_map`, `pdl_inactive`, `merge_events`, `pdl_id_aliases`
- [ADR-0001](0001-dbml-owns-table-shape-across-layers.md) (DBML as source of truth) — orthogonal but related
- [ADR-0006](0006-location-canonicalization-deferred.md) (location canonicalization deferred) — orthogonal but related
