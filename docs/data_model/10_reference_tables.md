# Reference Tables (`ref.*`) — Index

**Status:** Current; reflects [ADR-0011](../decisions/0011-loader-discovered-ref-tables.md)
**Governing decision:** ref.* is **loader-discovered from source data**; no seeded ref layer.
**Used by:** [doc 08 — Company](08_company.md), [doc 12 — Location](12_location.md), [doc 13 — Person](13_person.md)

`ref.*` holds canonical dimensions loaded from what PDL actually emits (Person bulk deliveries + PDL API Company Enrichment). Per ADR-0011, we don't seed ref tables from external standards or PDL canonical lists — those have their own drift schedules and we don't know when they update. Loader-discovered eliminates the drift question by construction: what's in `ref.*` mirrors what's currently in the source data.

This doc is the index across all `ref.*` tables. Per-domain specifics live in their own docs.

---

## Current ref-table catalog

### Place hierarchy — see [doc 12](12_location.md)

- `ref.continent` — loader-populated from PDL location.continent
- `ref.country` — loader-populated from PDL location.country. Uses PDL's free-text lowercased string as the natural key (see doc 12 §4.2 for the ISO-as-advisory design).
- `ref.state_province` — loader-populated from PDL location.region
- `ref.city` — loader-populated
- `ref.metro` — loader-populated
- `ref.location` — composite of country + state + city + metro

### Industry, job-title, seniority — see [doc 13 §5](13_person.md)

- `ref.industry` — loader-populated from PDL person.industry / experience.company.industry
- `ref.industry_v2` — loader-populated from PDL industry_v2 (person-side only; enrichment doesn't emit)
- `ref.job_title_class` / `ref.job_title_role` / `ref.job_title_subrole` — loader-populated from PDL experience.title.class / .role / .sub_role. V25 dropped the composite `ref.job_title_classification`; `integration.experience` has 3 independent FKs (Option E) to preserve PDL's partial classifications.
- `ref.seniority_level` — loader-populated from PDL experience.title.levels[]

### Personal attributes — see [doc 13 §5](13_person.md)

- `ref.skill` — loader-populated from PDL skills[]
- `ref.interest` — loader-populated from PDL interests[]
- `ref.language` — table exists but stays empty (PDL doesn't emit `languages[]` on the subscription tier this pipeline uses; there is no ref dbt model for it)

### PDL company relationships (V28) — see [doc 08 §4.3](08_company.md)

- `ref.pdl_relationship` — loader-populated from `staging.pdl_api_company_parsed.affiliated_entities[].relationship`. Observed values: `direct_subsidiary`, `indirect_subsidiary`, `immediate_parent`, `ultimate_parent`.

---

## Rebuild policy

`ref.*` rebuilds on every pipeline run from `raw.*` / `staging.*`. Loader-discovered rows re-derive from current data. **Surrogate `bigint` IDs in `ref.*` are not stable across rebuilds** — downstream consumers must query by natural keys (`name_lc`, `name`, `relationship`, etc.), never by stored surrogate IDs. See [ADR-0008](../decisions/0008-dbt-computed-ref-surrogate-ids.md) for the dbt-computed `ROW_NUMBER()` pattern.

Identity continuity for downstream consumers comes from natural keys (`pdl_id`, `pdl_company_id`) and, once identity resolution is built, the `catalog.person_key_map` ledger — not from `ref.*` surrogate IDs.

---

## Rejected patterns (historical record)

### Separate ref tables for NAICS / SIC / MIC — cut

`ref.naics_code`, `ref.sic_code`, `ref.mic_exchange` were originally planned but cut:

- PDL Company Enrichment emits NAICS/SIC as **rich classification objects** (not bare codes) with sector / sub_sector / industry_group / national_industry per element
- MIC is a single text scalar per company
- All three now live as `jsonb` arrays (`naics_codes`, `sic_codes`) or a `text` scalar (`mic_exchange`) directly on `integration.company` (V28)

See [doc 08 §4.1](08_company.md) for the V28 column shape and [design/18](../design/18_pdl_api_generic_caller.md) for the staging → integration path.

### Seeded ref-table layer (from external standards or PDL canonicals) — rejected per ADR-0011

Considered and rejected. Both external standards (NAICS releases every 5 years, ISO country updates, MIC quarterly updates) and PDL's canonical value tables (updated on PDL's schedule, no changelog feed) drift independently of our data. Any seeded layer creates a drift-detection burden without adding value — our consumers query by natural keys against `ref.*` regardless of whether the row was seeded or loader-discovered.

See [ADR-0011](../decisions/0011-loader-discovered-ref-tables.md) for the full alternative analysis and rejection reasoning.

### Composite ref.job_title_classification — dropped V25

Originally a composite ref table gluing (class, role, sub_role). Dropped V25 in favor of 3 independent FKs on `integration.experience` — the composite forced NOT NULL on all 3 columns, dropping the noticeable share of PDL experiences with partial classifications. See the V25 migration for details.

---

## References

- [ADR-0005](../decisions/0005-ref-population-layer.md) — ref tables are populated by their own dbt layer (`models/ref/`), not by staging
- [ADR-0008](../decisions/0008-dbt-computed-ref-surrogate-ids.md) — ref surrogate IDs are dbt-computed via `ROW_NUMBER()`; not IDENTITY
- [ADR-0011](../decisions/0011-loader-discovered-ref-tables.md) — loader-discovered ref layer (this doc's governing decision)
- [doc 08](08_company.md) — company schema; V28 additions
- [doc 12](12_location.md) — place hierarchy details
- [doc 13](13_person.md) §5 — person-attribute ref tables
- `modeling/dbml/ref.dbml` — structural contract
