# ADR-0006: Location canonicalization deferred

**Update (after [ADR-0011](0011-loader-discovered-ref-tables.md)):** The "future seed migration" premise in this ADR is superseded by [ADR-0011](0011-loader-discovered-ref-tables.md), which rejects the seeded ref-layer approach entirely (both external standards and PDL canonicals drift on their own schedules; loader-discovered eliminates the drift-detection burden). The location-canonicalization deferral itself stands — this ADR's premise that PDL data has dirt in the tail is still true; the deferred fix now takes the form of loader-side normalization, the PDL Location / School Cleaner APIs, or downstream cleansing routines ([pdl_data_cleansing/](../pdl_data_cleansing/)), not a seed migration.

## Context

PDL person staging produces `staging.pdl_person_addresses_unique`, which feeds the `ref.*` location hierarchy (`ref.continent`, `ref.country`, `ref.state_province`, `ref.city`, `ref.metro`, `ref.location`) via 6 dbt ref models. PDL claims to emit these location strings in canonical lowercase English (per their convention documented across the `ref.dbml` `name_lc` columns).

Profiling a full delivery shows PDL data is **not fully canonical**:

- `ref.state_province` source: noticeably more distinct region strings than ISO 3166-2 has subdivisions. Variants and PDL-specific subdivisions show up alongside canonical ones.
- `ref.city` source: canonical-ish, with dirt in the long tail.
- School names: far more distinct strings than there are schools; an abbreviation, the full name and a dotted variant ("EU" / "Example University" / "E.U.") coexist. Same problem class as location dirt.
- Bool placeholders: PDL emits literal `"false"` / `"true"` strings for some missing optional fields (e.g. `location_street_address`, `github_url`) — an adjacent issue, handled in staging ([design/15](../design/15_pdl_staging_design.md) §3).

Canonical data sources exist but require integration work to wire up:
- ISO 3166-1 alpha-2 / alpha-3 codes for countries (`ref.country.iso_alpha_2`, `iso_alpha_3` columns are already in DBML, NULL)
- ISO 3166-2 subdivision codes for states/provinces (`ref.state_province.iso_subdivision_code`)
- US Census MSA codes for metros (`ref.metro.msa_code`)
- PDL Location / School Cleaner APIs for location + school canonicalization

The architectural question: do we wire up canonical sources up front, or accept PDL-as-emitted and defer cleanup?

## Decision

**Defer location canonicalization** until one of these triggers:

- **A second source with its own location strings.** Cross-source location matching requires a normalization strategy — that is the natural moment to introduce ISO codes / Cleaner API output into the ref layer.
- **A consumer that needs canonical location join keys.** Search-by-location ergonomics ("show everyone in 'United States'" must work whether PDL emits `'us'` or `'united states'`) drives the need.

Whichever arrives first owns the work.

**Current behavior:**
- Ref tables (`continent`, `country`, `state_province`, `city`, `metro`, `location`) populate from whatever PDL emits in the current delivery.
- `LOWER()` defensive normalization in dbt SELECTs (cheap insurance against future PDL casing drift).
- `iso_alpha_2`, `iso_alpha_3`, `iso_subdivision_code`, `msa_code` columns stay defined in `ref.dbml` but NULL.
- Stateless rebuild means dirty values don't accumulate in a ledger — each delivery rebuilds the ref tables from scratch.

## Consequences

**Cost we accept:**

- Ref tables are "PDL-canonical" but not "globally canonical". If PDL emits both `'us'` and `'united states'` in a single delivery, they become two separate `ref.country` rows.
- Consumers filtering by location may hit imperfect matches. Acceptable until a consumer actually depends on it.
- The `iso_*` / `msa_code` columns are "advisory NULL" — readers see them in DBML and may wonder why they're unpopulated. Documented here and in [data_model/12](../data_model/12_location.md).

**Benefits:**

- The core pipeline shipped sooner; no canonical-data seed migration or fallback logic in the ref layer.
- The architecture pattern (additive ISO/MSA columns) is already in DBML; moving to canonical data later is a non-breaking change, not a re-architecture.
- If a second source ever arrives, canonicalization gets designed once with both sources in scope — a better outcome than a PDL-only solution that needs reworking.

**Risks:**

- If a consumer surfaces a real problem from the dirty data sooner than expected, the deferral was wrong and a faster fix is needed.
- Multi-source location matching, if it ever arrives, might force a heavier canonicalization push than anticipated.

## Alternatives considered

**A. Build an ISO seed migration up front.**
Land canonical ISO 3166-1 / 3166-2 / Census MSA data via a Flyway seed migration. Populate `iso_*` and `msa_code` columns; provide cross-reference for downstream search.
- *Rejected* because: delays the core pipeline; no consumer needs the canonical join yet. (Seeding is now rejected outright by ADR-0011.)

**B. Route all locations through the PDL Location Cleaner as part of the core ref build.**
Send raw PDL strings through the cleaner and store canonical values in `ref.*`.
- *Rejected at the time* because: it required API caller infrastructure (caching, cost tracking) not needed for the core pipeline. That caller now exists (`processing/pdl_api`, `pdl_api.location_input_list` / `location_cleaner_call`), but its output is not wired into the ref build; that stays deferred until a trigger above fires.

**C. Accept dirt forever, no canonicalization plan.**
*Rejected* because: location search genuinely cannot work well without some canonical join keys. This ADR defers but doesn't dismiss the need.

## Revisit triggers

- A second data source with its own location strings is added.
- A consumer needs canonical location join keys for search / filtering.
- Earlier, if any consumer (prototype, export, ad-hoc analysis) surfaces a real failure mode from the dirty location data.

## References

- [design/15](../design/15_pdl_staging_design.md) decision #3 — address pattern (one table, 3 source paths)
- [design/18](../design/18_pdl_api_generic_caller.md) — PDL API generic caller (Location / School Cleaners)
- `modeling/dbml/ref.dbml` — the `iso_alpha_2`, `iso_alpha_3`, `iso_subdivision_code`, `msa_code` columns (NULL; would be populated by this ADR's deferred work)
- [ADR-0005](0005-ref-population-layer.md) — ref population convention (orthogonal but related — dictates *where* ref population happens)
