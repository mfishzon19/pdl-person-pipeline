# ADR-0011: Ref tables stay loader-discovered (no seeded layer)

## Context

PDL publishes a full set of [Canonical Field Values](https://docs.peopledatalabs.com/docs/canonical-field-values) tables — formal vocabularies for the values it emits in API responses (relationship types, company sizes, NAICS hierarchy, job-title classes, etc.). The inventory of which canonical tables apply to our bundle is in [data_model/19](../data_model/19.pdl_canonical_value_tables.md).

Heading into the PDL Company Enrichment work, the question was whether `ref.*` tables should mirror PDL's canonical lists by **seeding from PDL documentation** (Flyway `R__` repeatable migrations with INSERT/COPY statements, re-run when PDL updates a list) or **continue with loader-discovered** (dbt model reading `staging.*` → `ref.*`, picks up whatever values appear in our actual data).

The 9 existing person-tier ref tables (`ref.industry`, `ref.country`, `ref.metro`, the 4 job-title dimensions, `ref.seniority_level`, `ref.continent`) were all loader-discovered. The choice was whether enrichment-era ref tables should diverge.

### Options considered

**Option A. Seeded `R__` ref layer from PDL canonical tables**

- For each in-bundle PDL canonical table, ship an `R__seed_<table>.sql` migration: `TRUNCATE ref.<table>; INSERT INTO ref.<table> (code, description) VALUES ...`
- Large code sets (NAICS ~1057 rows, SIC ~1000+, MIC ~2500, Location Countries ~249, Roles/Subroles ~150/500, Metros ~1000) shipped as CSV alongside `R__`, loaded via `COPY`.
- Small enums (Relationship Types ~4 rows, Company Sizes ~7, Inferred Revenue ~9, Sex ~4, etc.) inline INSERT.
- Optional separate schema (`pdl_ref` / `pdl_canonical`) for operational separation from loader-discovered tables.
- Drift detection: dbt tests on `staging.*` flagging values present in data but absent from the seed → test failure prompts a re-seed change.

Benefits: ref tables carry official descriptions / hierarchy attributes; missing-value detection becomes an automated test signal.

**Option B. Pure loader-discovered (same pattern as the existing ref tables)**

- New ref tables get populated by their own dbt model reading `staging.* → ref.*`, projecting `DISTINCT` natural-key values.
- Surrogate IDs assigned via `ROW_NUMBER()` per [ADR-0008](0008-dbt-computed-ref-surrogate-ids.md).
- No external seed list; the data IS the value list.
- PDL silently adds a new value → loader picks it up on next pipeline run.

Benefits: zero seed maintenance; consistent with the existing pattern; no drift to detect (one source of truth).

### Use-case rule (decided alongside)

Separately, we adopted a **use-case rule** for *whether* a value gets a ref table at all:

> Build a ref table only when the column has an active use case (searched, filtered, JOIN target). Otherwise the value stays as a `text` scalar or `jsonb` element on the integration row.

This collapses what looked like "20 new ref tables" (every in-bundle PDL canonical) into ~1 actually needed table (Relationship Types — used in `integration.company_affiliation` JOINs). The rest (Company Sizes, Types, Inferred Revenue, Funding Stages, NAICS/SIC/MIC, Education Degrees/Majors, School Types, Sex, Inferred Salaries) stay as `text` or `jsonb` on `integration.company` / `integration.person` / `integration.person_education` because nothing in our schema searches or joins on them.

## Decision

**Option B. Ref tables are loader-discovered.**

Concretely:

- The only new ref table for enrichment is `ref.pdl_relationship`, populated by a dbt model reading `staging.pdl_api_company_parsed` and projecting `DISTINCT $.affiliated_entities[].relationship`. `integration.company_affiliation.relationship_id` FKs into it.
- No seeded `R__` migrations.
- No separate `pdl_ref` / `pdl_canonical` schema.
- No CSV-loaded code sets (NAICS / SIC / MIC stay as hierarchy-preserving jsonb on `integration.company`, per the jsonb-vs-junction scope decision in [data_model/08](../data_model/08_company.md)).
- No drift-detection tests.
- The use-case rule (above) determines whether a new in-bundle field becomes a ref table or stays text/jsonb.

## Why Option B over Option A

1. **Drift detection only matters under Option A.** With one source of truth (the data), there is nothing to drift against. PDL adds a new relationship value → loader assigns it a `ROW_NUMBER` surrogate ID on next rebuild. No test failure to chase, no re-seed change to ship. Drift detection's "killer point" — required manual interaction whenever PDL changes anything — disappears when the question goes away.

2. **The use-case rule shrinks the seeded inventory to ~1 table.** Building seeded infrastructure (R__ pattern, CSV file location convention, optional schema split, drift tests, cadence policy) for a single 4-row table is over-engineering. The infrastructure cost dominates.

3. **External-standard rationale evaporates under the jsonb decision.** The strongest seeded case was external standards (NAICS / SIC / MIC) where PDL is mirroring ISO / federal codes that we might want with full hierarchy attributes. But the company scope decision ([data_model/08](../data_model/08_company.md)) already moved these to `jsonb` arrays on `integration.company` with per-element hierarchy preserved. There's no ref table to seed because there's no ref table at all.

4. **Surrogate-ID stability concerns are already accepted.** [ADR-0010](0010-extend-dbt-computed-surrogate-ids-to-integration.md) documents that surrogate IDs are unstable across rebuilds across the project. Seeded ref tables would carry the same instability (TRUNCATE + INSERT is still TRUNCATE + INSERT). Seeded buys nothing here.

5. **Silently accepting new PDL values is fine.** The premise behind drift detection was "we should block / be notified when PDL adds a value." But our data faithfully reflecting upstream values is the desired behavior. Consumers render the value directly; if a value appears that a consumer hasn't special-cased, that's a small downstream problem, not a data-quality problem.

6. **No descriptions / hierarchy attributes ≠ data quality problem.** PDL's canonical tables include human-readable descriptions for each code. Our consumers render the code/name directly — descriptions are nice-to-have, never load-bearing. If a consumer later asks for descriptions, we can add a single column or join layer at that point.

## Consequences

**Benefits:**
- Zero new seeded infrastructure (no `R__` pattern, no CSV file convention, no `pdl_ref` schema, no drift tests, no cadence policy).
- Enrichment ref-layer scope is exactly one new model (`ref.pdl_relationship`), following the same pattern as the existing ref models.
- Adding the next loader-discovered ref table follows a known, mechanical pattern.
- New PDL values are absorbed automatically; no operational interrupt.

**Costs:**
- Ref tables carry only the bare value (e.g., `direct_subsidiary`) — no PDL description, no hierarchy attribute. If a consumer later wants descriptions, we add a column at that point.
- No automated signal when PDL adds an unseen value. Risk model: silent expansion of the value set. Acceptable because (a) PDL adds values rarely and (b) we can spot-check via `SELECT DISTINCT` if needed.
- If we ever DO want a seeded ref table (genuinely external standard, hierarchy used by a consumer), this ADR has to be reopened. Likely candidate: NAICS or SIC if hierarchy search is needed. Currently moot under the jsonb decision.

**Risks:**
- A future requirement could force-fit a seeded layer (e.g., a compliance need for officially-named industries). This ADR gets revisited at that point — the move from loader-discovered to seeded is mechanical (one Flyway migration + one R__ + drop the dbt model).

## Alternatives explicitly rejected

- **Mixed seeded/loader by table size** (small enums inline, large code sets via CSV). Rejected — the use-case rule eliminated almost all the candidates; the remaining one is too small to justify the infrastructure.
- **Separate `pdl_ref` schema for seeded tables.** Moot under Option B (no seeded tables) but also rejected on its own merits: cross-schema FKs add maintenance cost; ref tables that ever get promoted to seeded would have to MOVE schemas (rename or live in both). Operational benefit (clearer ownership) didn't outweigh the maintenance cost.
- **Drift-detection tests without seeding.** Rejected — drift against what? Without a seed list, there's no second source to drift against. The proposal made sense only paired with a seeded layer.
- **Quarterly re-pull cadence from PDL docs.** Rejected with seeded — manual interaction at every PDL update is exactly the cost we're trying to avoid.

## What this falsifies / clarifies in existing docs

- [data_model/19](../data_model/19.pdl_canonical_value_tables.md) is trimmed to a one-page link inventory of PDL canonical tables (A: in our bundle / B: not in our bundle). The decision section moved to this ADR.
- No DBML or schema change required. No new schemas. No new migrations beyond V28 (which is unrelated — covers integration.company enrichment additions + `integration.company_affiliation`).

## Revisit triggers

- A consumer needs a feature that requires PDL's canonical description text or hierarchy attributes for a value type we don't already preserve (e.g., NAICS hierarchy via dedicated tables instead of jsonb).
- A compliance requirement to use an officially-mirrored vocabulary instead of values discovered from our data.
- PDL changes a value's NAME between datasets (e.g., renames `direct_subsidiary` to `wholly_owned_subsidiary`). Loader-discovered creates a new row; the old row stays. We'd notice via volume change; this ADR doesn't change.

## References

- [ADR-0001](0001-dbml-owns-table-shape-across-layers.md) — DBML as source of truth
- [ADR-0005](0005-ref-population-layer.md) — ref tables populated by their own dbt layer
- [ADR-0008](0008-dbt-computed-ref-surrogate-ids.md) — ref-table surrogate IDs are dbt-computed via ROW_NUMBER
- [ADR-0010](0010-extend-dbt-computed-surrogate-ids-to-integration.md) — surrogate IDs unstable across rebuilds (accepted project-wide)
- [data_model/19](../data_model/19.pdl_canonical_value_tables.md) — PDL canonical tables link inventory + bundle audit
- [data_model/08 §4.3 + §6](../data_model/08_company.md) — the relationship model that uses `ref.pdl_relationship`
- [design/18](../design/18_pdl_api_generic_caller.md) — PDL API generic caller / enrichment pipeline (consumes this decision)
