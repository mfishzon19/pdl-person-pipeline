# PDL Company Fields — Change Frequency Buckets

This document categorizes the fields on the official [Company Changelog Fields](https://docs.peopledatalabs.com/docs/company-changelog-fields) list — the set of fields People Data Labs monitors to flag whether a company record has changed between dataset releases.

Fields are grouped by how often and why they typically change, to help inform refresh and caching strategy.

---

## Bucket 1: Frequently Changing

Fields that tend to update most releases on active companies, either because the company itself updates them or because PDL refines its detection and standardization logic.

| Field | Notes |
| --- | --- |
| `size` | Self-reported headcount range; updated when the company changes it on social profiles |
| `inferred_revenue` | Recalculated by PDL's predictive model each release |
| `tags` | PDL adds/removes tags as sources evolve |
| `summary` | Tracks the company's self-reported description |
| `headline` | Short summary; tracks the company's self-description |
| `location` | HQ — full object can shift |
| `location.name` | |
| `location.locality` | |
| `location.region` | |
| `location.metro` | |
| `location.country` | |
| `location.continent` | |
| `location.street_address` | |
| `location.address_line_2` | |
| `location.postal_code` | |
| `location.geo` | |
| `industry` | Self-reported; may also shift as PDL improves mapping |
| `naics` | Full NAICS object |
| `naics.naics_code` | |
| `naics.sector` | |
| `naics.sub_sector` | |
| `naics.industry_group` | |
| `naics.naics_industry` | |
| `naics.national_industry` | |
| `sic` | Full SIC object |
| `sic.sic_code` | |
| `sic.major_group` | |
| `sic.industry_group` | |
| `sic.industry_sector` | |
| `profiles` | List of social profile URLs; additive over time |
| `linkedin_url` | Can change if the canonical URL is updated |
| `facebook_url` | |
| `twitter_url` | |
| `alternative_names` | Additive as PDL discovers more name variants |
| `alternative_domains` | Additive as PDL discovers more domain variants |

---

## Bucket 2: Event-Driven

Fields that change when something real happens to the company — funding rounds, M&A, IPOs, rebrands. Updates here usually signal a material business event.

| Field | Triggering Event |
| --- | --- |
| `funding_details` | New funding round announced |
| `funding_details.funding_currency` | |
| `funding_details.funding_raised` | |
| `funding_details.funding_round_date` | |
| `funding_details.funding_type` | |
| `funding_details.investing_companies` | |
| `funding_details.investing_individuals` | |
| `funding_stages` | New funding round |
| `last_funding_date` | New funding round |
| `latest_funding_stage` | New funding round |
| `number_funding_rounds` | New funding round |
| `total_funding_raised` | New funding round |
| `ticker` | IPO, delisting, ticker change |
| `mic_exchange` | Exchange listing change |
| `type` | Going public, going private, becoming a `public_subsidiary` |
| `immediate_parent` | Acquisition, divestiture, restructuring |
| `ultimate_parent` | Acquisition, divestiture, restructuring |
| `all_subsidiaries` | Acquisition, divestiture |
| `direct_subsidiaries` | Acquisition, divestiture |
| `affiliated_profiles` | Any change in parent/subsidiary relationships |
| `name` | Rebrand (e.g., Acme Corp renames itself Acme Group) |
| `display_name` | Rebrand |
| `website` | Primary domain change |

---

## Bucket 3: Slow-Moving but Not Immutable

Fields that look static but can still change — usually because PDL got better data, not because the underlying fact changed.

| Field | Why It Can Change |
| --- | --- |
| `founded` | PDL picks the year appearing in the most sources; can shift as sources update, or a `null` can become populated |
| `linkedin_id` | Generally stable but can change if the company recreates its LinkedIn page |
| `linkedin_slug` | Generally stable but can change with page recreation or LinkedIn URL changes |

---

## Persistent Field (Not on Changelog List)

| Field | Notes |
| --- | --- |
| `id` | The PDL Company ID is the only company field intended to be truly persistent across releases. It is **not** on the changelog list because it doesn't change — it's the anchor used to detect changes in everything else. |

---

## Fields NOT Tracked by the Changelog (but still change every release)

The Company Changelog list above is PDL's conservative "meaningful change" signal — fields used to flag a record as updated in [Delta File Deliveries](https://docs.peopledatalabs.com/docs/delta-file-deliveries). It does **not** include the Company Insights / aggregation fields, which are recomputed every release and will almost always differ between dataset versions even when nothing on the changelog list moves.

Examples of fields recomputed each release but NOT tracked by the changelog:

- `employee_count`, `employee_count_by_country`, `employee_count_by_role`, `employee_count_by_class`, `employee_count_by_sub_role`
- `employee_count_by_month`, `employee_count_by_month_by_role`, `employee_count_by_month_by_level`
- `employee_growth_rate`, `employee_churn_rate`, `employee_turnover_rate`, `annualized_employee_turnover_rate`
- `employee_growth_rate_12_month_by_role`, `employee_growth_rate_12_month_by_sub_role`, `employee_growth_rate_12_month_by_class`, `employee_growth_rate_12_month_by_country`
- `average_employee_tenure`, `average_tenure_by_level`, `average_tenure_by_role`
- `median_employee_tenure`, `median_tenure_by_level`, `median_tenure_by_role`
- `gross_additions_by_month`, `gross_departures_by_month`
- `recent_exec_hires`, `recent_exec_departures`
- `top_next_employers`, `top_next_employers_12_month`, `top_previous_employers`, `top_previous_employers_12_month`
- `top_us_employee_metros`
- `linkedin_follower_count`
- `locations`, `num_active_locations`, `num_total_locations`
- `affiliated_entities`
- `dataset_version`

If your refresh strategy needs to detect *any* change, you'd have to diff these yourself. If you only care about material changes (the kind PDL itself considers a record "updated"), the changelog list in Buckets 1–3 above is the right signal.

---

## Refresh Strategy Implications

- **Bucket 1 (frequently changing)** is the main reason to re-enrich on a regular cadence (monthly aligns with PDL's API release cycle).
- **Bucket 2 (event-driven)** is why you don't want to cache indefinitely — funding, M&A, and IPO events materially change the record.
- **Bucket 3 (slow-moving)** is why even "stable" fields shouldn't be assumed immutable in your data model.
- **Aggregation fields** (not in the changelog list) drift every release; if you display growth/churn/headcount trends, refresh frequently.
- **`id`** is the only field safe to treat as a persistent key.

---

*Source: [PDL Company Schema](https://docs.peopledatalabs.com/docs/company-schema) and [Company Changelog Fields](https://docs.peopledatalabs.com/docs/company-changelog-fields)*
