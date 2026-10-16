# Cleansing Layer — design

**Status:** Draft. The cleansing rules are prototyped as R&D SQL in [`../pdl_data_cleansing/`](../pdl_data_cleansing/); this doc is the target pipeline shape they graduate into.
**Companion docs:** [`15_pdl_staging_design.md`](15_pdl_staging_design.md), [`16_dbt_pipeline_layers.md`](16_dbt_pipeline_layers.md), [`18_pdl_api_generic_caller.md`](18_pdl_api_generic_caller.md), [`../pdl_data_cleansing/README.md`](../pdl_data_cleansing/README.md)

**Motivation:** without a single design, cleansing concerns end up scattered — `LOWER(TRIM)` sprinkled across parsed models, PDL canonical-ID resolution done ad hoc, display-casing applied at the wrong layer. This doc says where each concern lives, which classes of cleansing exist, and how the display-vs-join distinction works.

---

## Contents

- [1. Scope + what's not cleansing](#1-scope--whats-not-cleansing)
- [2. Layer position](#2-layer-position)
- [3. Class taxonomy](#3-class-taxonomy)
- [4. Casing convention](#4-casing-convention)
- [5. Function library](#5-function-library)
- [6. Model shape](#6-model-shape)
- [7. Real-data findings](#7-real-data-findings)
  - [7.1 PDL degree canonicalization finding](#71-pdl-degree-canonicalization-finding)
- [8. Priority-ordered scope](#8-priority-ordered-scope)
- [9. LinkedIn URL dedup](#9-linkedin-url-dedup)
- [10. Not-in-scope, tracked](#10-not-in-scope-tracked)
  - [10.1 Translation of PDL prose fields — architecture and cost](#101-translation-of-pdl-prose-fields--architecture-and-cost)

---

## 1. Scope + what's not cleansing

**Cleansing IS**: dedup on non-primary-key groupings, quarantine-non-winners for shared-identifier collisions, synonym / variant rollup across differently-spelled labels, row filters (invalid names, broken PDL company entities), and casing / display-form generation.

**Cleansing IS NOT**:
- **Parsing** — JSON unnest, type-cast, HTML strip. Lives at `_parsed` ([15](15_pdl_staging_design.md)).
- **External canonical-ID resolution** — a PDL cleaner call → `pdl_company_id` / `pdl_school_id` / canonical location name. That's API resolution, not text normalization, and is owned by the PDL API caller ([18](18_pdl_api_generic_caller.md)). Referred to below as Class A for completeness.
- **Structural transforms** — multi-value split (`major = "History, Political Science"` → 2 rows), 1:N break-out. A data-model decision, handled at `_parsed` by choosing the right destination shape.

## 2. Layer position

Cleansing runs at a **`_cleaned` staging tier** between `_unique` and integration:

```
_parsed → _unique → _cleaned → (_staged, optional) → integration.*
                       ▲
                       └── Class A joins (PDL API audit) + Class B/C/D/E cleansing
```

`_cleaned` is a per-source tier, like `_staged` ([16](16_dbt_pipeline_layers.md)). PDL is the only source, so every `_cleaned` model is a `pdl_person_*` model. Display-form generation for columns owned at integration (e.g. a column computed in `integration.company`) happens in that integration model.

Ref + integration tables therefore consume **already-cleansed** data. Cleansing is not a downstream JOIN concern; it's completed upstream.

**Where the R&D runs.** The files in [`../pdl_data_cleansing/`](../pdl_data_cleansing/) read from `integration.*` for convenience (a local database with a PDL delivery built through integration) and write to a scratch `cleansing_rad` schema. That inverts the target flow on purpose — it lets rules be iterated against fully-joined data. Each rule moves upstream into `_cleaned` when it graduates (see [§6](#6-model-shape)).

## 3. Class taxonomy

**Class A — External canonical-ID resolution**: PDL cleaner queue + audit + LEFT JOIN on the queue's natural key. Owned by [18](18_pdl_api_generic_caller.md). Listed here for completeness; the classes below are what THIS doc adds.

**Class B — Dedup on a non-PK identifier**: multiple records share a natural key that isn't the table's primary key. Examples: two `pdl_person_unique` rows with the same LinkedIn URL (§9, `person_dedup_on_linkedin.sql`); duplicate employment / education rows for one person (`experience_duplicate.sql`, `education_duplicate.sql` + `education_is_keep.sql`). Resolution: classify the cluster, choose one winner via completeness / freshness signals; non-winners dropped from `_cleaned`.

**Class C — Group-share identifier → keep one, quarantine rest**: identical to Class B in mechanism. Distinct as a design lens because the semantic is "several records claim the same identity" (LinkedIn URL, email) vs Class B's "the same identity appears many times." Both collapse to the same `ROW_NUMBER` filter; kept separate so reviewers can see both framings were considered.

**Class D — Synonym / variant rollup**: differently-spelled labels roll up to a single canonical value. Examples: school-name variants and sub-units under one canonical school (`school_canonical_rollup.sql`); degree strings collapsed to a degree family (`degree_family.sql`); subsidiaries, regional offices and predecessors rolled up under a parent company via a user-supplied company hierarchy (`company_hierarchy_load.sql` → `company_hierarchy_pdl_match.sql` + `scripts/company_hierarchy_pdl_cleaner.py` → `company_hierarchy_edges.sql`). Requires a synonym map — curated, PDL-derived, or both.

**Class E — Filter**: entire rows dropped based on a row-level predicate. Examples: invalid / placeholder person names (`invalid_names_filter.sql`); broken PDL company entities where a role or occupation token was fused into a bogus company (`func_is_broken_pdl_company.sql` + `broken_pdl_company_apply.sql`). Filtered rows are not quarantined — a non-stateful `WHERE NOT <predicate>` at `_cleaned`. Population-scoping filters (e.g. restricting to a set of industries) are a consumer concern and are not part of this layer; the industry ERD surface is in `modeling/dbml/scopes/industry.txt` for anyone designing one.

**Casing / display-form generation** is not a separate class — it's a transformation applied to columns owned at the layer. Details in §4.

**Quarantine posture**: non-stateful. Non-winners of Class B/C simply don't propagate to `_cleaned`. No `quarantine.*` schema, no audit table. If audit is needed later it can be added without fighting the mechanism.

## 4. Casing convention

**Rule**: lowercase for join/lookup keys; a companion display column for user-facing rendering.

**Storage pattern** (repeats across tables):

| Column | Purpose | Example |
|---|---|---|
| `name_lc` | Canonical join/filter form | `o'brien`, `united states`, `chief technology officer` |
| `name_display` | Display form | `O'Brien`, `United States`, `Chief Technology Officer` |

**Existing convention holds** — `ref.continent`, `ref.country`, `ref.state_province`, `ref.city`, `ref.metro` already carry `name_lc`. This doc extends the pattern by adding `name_display` companion columns wherever a display value is needed.

**Casing rules for the display function**:
- Standard tokens: `initcap()` per whitespace-split token
- Apostrophes preserved: `o'brien → O'Brien` (both letters capitalize; apostrophe stays); same for `d'souza → D'Souza`
- Mc-family: `mcdonald → McDonald` (capitalize the third character)
- Multi-token particles: `de oliveira → De Oliveira`, `van der merwe → Van Der Merwe` (title-case each token)
- Hyphens preserved: `smith-jones → Smith-Jones`
- Small words in titles: `vice president of sales → Vice President of Sales` (of/the/and lowercase mid-string, capitalized at leading position)
- Acronym exceptions: `cto → CTO`, `vp → VP`, `phd → PhD` — maintained in a per-function list

**Exceptions to the lowercase-storage rule** (stored as received):
- ISO codes: `iso_alpha_2 = "US"`, `iso_subdivision_code = "US-CA"`
- Stock tickers: `ticker = "ACME"`
- Postal codes: `postal_code = "M5V 3A8"` (Canadian) or `10001` (US)
- Middle/last initial: `middle_initial = "A"`, `last_initial = "B"`

**Display form never replaces the join form.** Proper-casing a column in place at staging breaks the lowercase join key. Display output always goes into a `*_display` companion column (e.g. `first_name_display`) alongside the lowercase primary.

## 5. Function library

**Multiple purpose-specific Postgres functions**, not one god-function. They are prototyped as `cleansing_rad.func_*` in [`../pdl_data_cleansing/`](../pdl_data_cleansing/):

| R&D function | Purpose |
|---|---|
| `func_normalize_person_name(text)` | Person name: Unicode NFC, credential-suffix stripping (`PhD`, `MBA`, …), honorific-prefix stripping (`Dr.`, …) |
| `func_normalize_title(text)` | Job title: strip administrative noise, collapse role variants |
| `func_normalize_company_name(text)` | Company name: Unicode NFC, ASCII-fold typographic punctuation, whitespace collapse |
| `func_company_brand(text)` | Brand core: strip corporate-entity suffixes (`Inc`, `LLC`, `Ltd`, `GmbH`, `AG`, `Pty Ltd`, …) |
| `func_normalize_linkedin_url(text)` | LinkedIn URL canonicalization (strip protocol, `www`, country subdomain, trailing path) — the form both sides of a dedup JOIN use |
| `func_linkedin_slug(text)` | Extract the company / person slug from a LinkedIn URL |
| `func_normalize_location(text)` | City / state / country cleanup, casing, punctuation |
| `func_normalize_prose(text)` | PDL `headline` / `summary`: Unicode, whitespace, punctuation |
| `func_is_broken_pdl_company(...)` | Class E predicate for fused role-token company entities |

Display-form functions (§4) follow the same pattern: e.g. a person-name display function, a title display function (small words + acronyms), a geographic display function, company / school display functions that preserve suffixes and abbreviations.

**Pipeline shape**: each function graduates into a repeatable Flyway migration (`R__func_<name>.sql`). Row-level, deterministic, `IMMUTABLE` — safe in expression indexes and callable from dbt or ad-hoc SQL. Not dbt macros (a macro is a compile-time text template and can't back an index).

**Testing rule**: per-function dbt singular test with input/output cases (one test file per function, or one aggregated test with cases per function). Cases include: happy path, particle edges, empty/NULL, trim behavior.

**Source-agnostic**: each function takes plain text, so it applies to any source's columns. That's the point — one place to update the rule.

## 6. Model shape

**One `<source>_<domain>_cleaned` dbt model per (source, domain)**. It applies ALL cleansing concerns for that domain: LOWER discipline (if drift exists), Class A joins, dedup, filter, non-stateful quarantine, display generation.

Target models:

```
staging.pdl_person_cleaned               ← person: invalid-name filter, LinkedIn dedup, *_display names
staging.pdl_person_experience_cleaned    ← experience duplicate clusters → winner rows; broken-company filter
staging.pdl_person_education_cleaned     ← null-degree rescue → duplicate clusters → winner + field merge
staging.pdl_person_companies_cleaned     ← company-name normalization, brand, hierarchy rollup
staging.pdl_person_schools_cleaned       ← school canonical rollup
staging.pdl_person_addresses_cleaned     ← location normalization
```

**How each R&D artifact graduates** (rule of thumb from [`../pdl_data_cleansing/README.md`](../pdl_data_cleansing/README.md)):

- **Row-level, string-to-string, deterministic** → Postgres function (`R__func_*.sql`).
- **Row-level boolean filter** (Pattern A: no JOINs / aggregates) → predicate function + inline `WHERE NOT <predicate>(...)` in the domain's `_cleaned` model. E.g. `invalid_names_filter.sql` → `R__func_is_invalid_name.sql`.
- **Set-level, produces a table** (Pattern B: JOINs, aggregates, tiebreaks) → the whole file becomes a `_cleaned` dbt model or a CTE inside one. E.g. `person_dedup_on_linkedin.sql`, `experience_duplicate.sql`, `education_duplicate.sql`, `school_canonical_rollup.sql`, `company_hierarchy_edges.sql`.
- **Curated, human-reviewable maps** → seed / ref table, not re-derived each run. E.g. `degree_family.sql` → `ref.degree_family`; the company hierarchy CSV → a seed loaded by the `company_hierarchy_load` model.
- **External API calls** → a `PDLCaller` subclass in `processing/pdl_api/` ([18](18_pdl_api_generic_caller.md)). E.g. `scripts/company_hierarchy_pdl_cleaner.py` → queue rows on `pdl_api.company_input_list` drained by the company cleaner; the `_cleaned` model reads `pdl_api.company_cleaner_call`.

**dbt materialization**: default staging recipe (incremental + append + TRUNCATE pre_hook). No `materialized='table'` override — the target is Flyway-owned.

**Queue population**: if a cleansed domain also needs to feed a PDL API queue (`pdl_api.<domain>_input_list`), that INSERT belongs upstream of `_cleaned` (e.g. a post-hook on the parent `_unique` model or a separate population step), not inside `_cleaned`. `_cleaned` only reads the queue + `source('pdl_api', '<domain>_cleaner_call')`.

## 7. Real-data findings

Profiling a full PDL Person delivery built through integration gave these design inputs (exact counts are deliberately not recorded here):

- **Casing drift** (values that change under `LOWER(TRIM(...))`): person first / middle / last / full names, school names, experience titles and the `ref` place tables (`name_lc`) are effectively clean — zero or a handful of rows. `integration.company.name` is the one column with **real drift** (a small fraction of rows, but enough to split joins); `ref.skill.name` has a trivial amount. Both are fixed by applying `LOWER(TRIM())` at load.
- **Name particles** in `integration.person.last_name` (inputs for the person-name display function): apostrophe names (`o'brien`, `d'souza`), the Mc-family (`mcdonald`), and multi-token particles (`de oliveira`, `van der merwe`) each occur in the thousands. Apostrophes also appear in a small percentage of company and school names.
- **Title acronyms**: only a tiny fraction of experience titles match the acronym hint list, so title display-casing is low priority.
- **Duplicate clusters**: `experience_duplicate` and `education_duplicate` each find duplicate clusters covering a meaningful share of rows (hundreds of thousands to millions on a full delivery), spread across a few dozen distinct status combinations. `education_null_degree_rescue` fills a share of null-degree rows from a sibling entry, which noticeably raises the education cluster-match rate.

### 7.1 PDL degree canonicalization finding

`integration.person_education.degrees` (jsonb text array) has **only on the order of a hundred distinct values** across tens of millions of mentions. PDL canonicalizes upstream — no string cleansing is needed on this axis. What varies is **specificity**: the same education can appear as `["masters"]` on one row and `["master of science","masters"]` on another. `degree_family.sql` collapses every observed form to `bachelors` / `masters` / `doctorates` / `associates` (nothing falls to `other`) so both hash to the same cluster key in `education_duplicate`.

`doctorates` is PDL's catch-all for unclassified doctorate types (PhD, MD, EdD, …); it cannot be split further without a school-name or field-of-study heuristic.

## 8. Priority-ordered scope

**Priority 1 — must-have**:
1. `integration.person.{first,middle,last,full}_name` — add `_display` companion columns via a person-name display function.
2. **`integration.company.name` drift fix** — `LOWER(TRIM)` in the `integration.company` dbt SELECT (not applied yet). The drifted rows resolve on the next full rebuild (TRUNCATE + INSERT); no backfill migration needed.
3. **Invalid-name + broken-company filters** (Class E) — predicate functions + inline `WHERE NOT` in `_cleaned`.

**Priority 2 — cheap follow-ons**:
4. Add `name_display` companion to `ref.{continent, country, state_province, city, metro}` — small tables, applied on ref rebuild.
5. `ref.skill.name` `LOWER(TRIM)` at load — same pattern as the company drift fix.
6. **Experience + education duplicate collapse** — move the cluster + winner logic into `_cleaned` (education: rescue → cluster → winner + field merge).

**Priority 3 — deferred**:
7. `integration.experience.title_display` — acronym-adjacent titles are a tiny fraction, so low priority.
8. `integration.company.name_display` + `integration.school.name_display` — display form for company + school labels; spelling variance not yet quantified.
9. **LinkedIn URL person dedup** (§9) — mechanically simple, but needs the signal choice confirmed.
10. **School canonical rollup + company hierarchy rollup** (Class D) — needs the synonym / hierarchy map to be reviewed before it drives integration.

## 9. LinkedIn URL dedup

**Where**: `staging.pdl_person_cleaned`. R&D version: [`person_dedup_on_linkedin.sql`](../pdl_data_cleansing/person_dedup_on_linkedin.sql).

**Mechanism**:

```sql
WITH ranked AS (
  SELECT ...,
         normalize_linkedin_url(linkedin_url) AS linkedin_url_lc,
         ROW_NUMBER() OVER (
           PARTITION BY normalize_linkedin_url(linkedin_url)
           ORDER BY job_last_changed  DESC NULLS LAST,
                    job_last_verified DESC NULLS LAST,
                    loaded_at         DESC
         ) AS dedup_rank
  FROM staging.pdl_person_unique
  WHERE linkedin_url IS NOT NULL
)
SELECT * FROM ranked WHERE dedup_rank = 1
```

**Freshness signal ordering**: `job_last_changed` DESC → `job_last_verified` DESC → `loaded_at` DESC. The first two are populated on most, not all, PDL persons; `loaded_at` is the ultimate fallback.

**Non-winners**: silently dropped by the `WHERE dedup_rank = 1` filter. No quarantine schema.

**Rows with NULL LinkedIn URL**: not part of the dedup (excluded by `WHERE linkedin_url IS NOT NULL`), pass through unchanged.

## 10. Not-in-scope, tracked

- **Multi-value school hierarchy** (campus / sub-unit as separate entities) — a schema decision, not cleansing.
- **Company + school name-variance rollup (Class D) beyond the R&D maps** — needs profiling of real-data variance before a mechanism is chosen.
- **Rows in the company hierarchy without a PDL id** — options are (a) create them in `integration.company` with `pdl_company_id = NULL`, (b) only wire matched-both-sides edges into `integration.company_affiliation`, or (c) keep them in R&D only. Decision belongs to the pipeline model design.
- **Cross-source merge** — PDL is the only source. If another source is added, a deterministic match waterfall (normalized LinkedIn URL → name + current company + location composite → new id) would live in the `integration.person` model, reading every per-source `_cleaned` table.
- **Case-based fixups on `integration.company.name_display` + `.school.name_display`** — waits on profiling to show how much case variance there is.
- **Translate PDL person `headline` + `summary` to English** — §10.1.

### 10.1 Translation of PDL prose fields — architecture and cost

**Scope**: `integration.person.headline` + `.summary` (from PDL `$.headline` + `$.summary`). Both land verbatim; both often arrive non-English (profiles are global). Same treatment could later extend to `integration.experience.summary`, `integration.person_education.summary`, `integration.company.headline` + `.summary`; person is the highest-value surface.

**Architecture** — translation runs **outside Postgres**, with results cached in an audit table joined at cleansing time. Same shape as the PDL API audit tables ([18](18_pdl_api_generic_caller.md)):

```
Python cleansing task
    ├── select distinct source_text from staging.pdl_person_unique.{headline,summary}
    ├── LEFT JOIN staging.translation_audit  → find uncached strings
    ├── (optional) language-detect gate — skip English via fasttext/langid — free
    ├── call a translation API for uncached, non-English strings
    ├── UPSERT audit rows {source_text, source_lang, translated_en, api, model, cost, ts}
    └── staging.pdl_person_cleaned joins to audit for headline_en + summary_en
```

**Why not in-DB**: no Postgres extension does high-quality translation natively, and calling an external API from SQL would embed API keys, retries, cost tracking and rate limits where they don't belong.

**Workload**: a full delivery is millions of persons with a short headline and a summary of a few hundred characters each — billions of characters raw. A language-detect gate (most records are English) plus string-level dedup on shared template phrases cuts that by a large factor.

**Cost levers** (apply on top of any provider):

| Lever | Effect |
|---|---|
| Language-detect gate before calling the API (fasttext / langid, free) | Skips the majority of records — biggest single lever |
| Distinct-string dedup — many `headline` / `summary` strings repeat | A further meaningful reduction |
| Scope to the persons a consumer actually needs | Proportional |
| On-demand vs backfill — translate only when a record is read | Depends on access pattern; can push the long tail near zero |

Order-of-magnitude provider comparison for the gated, deduped workload: a small general-purpose LLM is in the low hundreds of dollars for a full backfill; dedicated machine-translation APIs are roughly an order of magnitude more; self-hosted open-source models are cheap per character but carry setup and per-language validation cost.

**Population strategy** — the durable artifact is the same `staging.translation_audit` cache whichever is chosen; strategy is a knob, not a schema decision:

| Strategy | When it wins |
|---|---|
| **A. Full precompute (backfill)** | Full-text search or facets over translated text are needed, or most records will be read |
| **B. On-demand (translate on first read, cache)** | Access is skewed toward a small hot set |
| **C. Hybrid — precompute hot set + on-demand tail** | Best of both; same cache serves both paths |

**Open design decisions**:

1. Destination column shape — `headline_en` / `summary_en` companion columns (retain source verbatim), OR overwrite with English + `headline_lang` / `summary_lang` provenance tags. Preference: companion columns — no data loss, consumers pick `COALESCE(headline_en, headline)`.
2. Language-detect strategy — client-side (fasttext / langid) or provider-side. Preference: client-side gate to minimize API cost.
3. Audit table shape — one row per unique source string with `api` / `model` / `cost_cents` metadata, so re-runs with a different provider are traceable.
4. Prompt / parameters — for an LLM path, a deterministic prompt (JSON output: `{lang, translated}`) at low temperature.
