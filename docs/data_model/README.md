# Data Model

The `ref.*` + `integration.*` structure the pipeline builds from PDL data (pipeline step 4). One doc per entity or concern. Pair with `modeling/dbml/*.dbml` (the structural contract) — these docs are the prose that explains it, including which PDL field populates each column.

- [08_company.md](08_company.md) — `integration.company` built from person-embedded company data, PDL Company Enrichment and affiliation stubs; `integration.company_affiliation` and `ref.pdl_relationship`.
- [10_reference_tables.md](10_reference_tables.md) — every `ref.*` table, the rule that they are built from what PDL actually sends (never pre-loaded), rebuild policy, rejected patterns.
- [11_pdl_company_field_change_buckets.md](11_pdl_company_field_change_buckets.md) — PDL company fields grouped by how often they change, to guide re-enrichment and caching.
- [12_location.md](12_location.md) — place hierarchy (`ref.continent` → country → state / province → city / metro → `ref.location`) and address fields on entity tables, with the PDL-to-schema mapping.
- [13_person.md](13_person.md) — `integration.person`, experience, education, school, all person / experience junctions, and the PDL column mapping (§6).
- [14_sources.md](14_sources.md) — sources: PDL Person bulk delivery and the PDL API (enrichment and cleaners), their pipeline paths, and the `source` columns in the model.
- [19.pdl_canonical_value_tables.md](19.pdl_canonical_value_tables.md) — PDL's canonical value tables, split into those that land as `ref.*` tables and those that stay text / jsonb.
