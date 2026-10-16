# PDL data cleansing routines

Step 5 of the pipeline (see [`../README.md`](../README.md)): the routines that clean PDL data once it has been parsed, enriched and shaped into `ref.*` + `integration.*`. Each routine here is a self-contained SQL (or Python) file that targets one data-quality problem in PDL data, builds the fix as tables or functions in a scratch schema, and ends with verification queries for reviewing the result.

**These files are the R&D form of the cleansing logic, not the pipeline implementation.** They read from `integration.*` for convenience. In the target design ([`../design/21_cleansing_layer_design.md`](../design/21_cleansing_layer_design.md)) the same logic runs **upstream of `integration.*`** — as Postgres functions plus dbt models at the per-source `_cleaned` staging tier (between `_unique` and `_staged`) — so `integration.*` is built from already-cleaned data. Every file starts with a DISCLAIMER banner saying so. [§ Path into the pipeline](#path-into-the-pipeline) maps each file to its pipeline shape.

## Contents

- [Prerequisites](#prerequisites)
- [The `cleansing_rad` schema](#the-cleansing_rad-schema)
- [Order of application](#order-of-application)
- [Routines](#routines) — [normalization functions](#1-normalization-functions) · [company](#2-company-routines) · [person](#3-person-routines) · [experience](#4-experience-routines) · [education](#5-education-routines) · [school](#6-school-routines)
- [Path into the pipeline](#path-into-the-pipeline)
- [Open questions](#open-questions)
- [Directory layout](#directory-layout)

## Prerequisites

- The local stack is up and a PDL delivery has been built through `integration.*` (`make dev-up`, then `make pipeline-pdl`; see the [top-level README](../../README.md)). For the company-hierarchy routine, company enrichment must also have run so `integration.company` is populated.
- `DATABASE_URL` points at the local database, e.g. `postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl`.
- Postgres 15+ (the local stack runs Postgres 18). The only extension used is `pg_trgm`, which the files that need it create themselves; `unaccent` is not needed.
- The Python script also needs `psycopg2` and `requests` (both available in the `pdl_test` conda env) and, when run with `--execute`, `PDL_API_KEY`. With `--execute` it calls the real PDL API and spends credits; never run it from tests.

Run each file from the repo root (some use client-side `\copy` with repo-relative paths):

```bash
psql "$DATABASE_URL" -c 'create schema if not exists cleansing_rad'
psql "$DATABASE_URL" -f docs/pdl_data_cleansing/<file>.sql
```

Each SQL file is idempotent: it drops and rebuilds its own outputs (or, for `education_is_keep.sql`, re-runs an `UPDATE`). Most files end with `V*` / `CHECK` verification queries so the output can be reviewed in place; `broken_pdl_company_apply.sql` only previews, and its `DELETE`s stay commented out until you enable them.

## The `cleansing_rad` schema

Everything produced here lands in a dedicated schema, `cleansing_rad` (`rad` = R&D), side by side with `integration.*` so the two can be joined freely without polluting `integration.*`.

- **Isolation.** `integration.*` is the pipeline contract (DBML-owned). Hand-written derived tables stay out of it.
- **Freedom to break things.** Drop, rebuild and rename at will — nothing downstream depends on `cleansing_rad.*`.
- **Clean migration path.** When a rule proves out, its output table maps 1:1 to a `_cleaned` dbt model (or its predicate to a Flyway `R__` function). The target schema changes; the semantics carry over.

| naming pattern | example | meaning |
|---|---|---|
| `func_*` | `func_company_brand` | IMMUTABLE Postgres function, callable inline and safe in expression indexes |
| `<domain>_*` | `education_duplicate`, `company_hierarchy_edges` | derived table for one data domain |
| `*_filter` | `invalid_names_filter.sql` | file that classifies rows into keep / drop sets |

## Order of application

Dependencies flow top to bottom. Independent chains can run in any order relative to each other.

```
0. func_*.sql                              normalization functions — apply first, any order
                                           (func_normalize_person_name before invalid_names_filter;
                                            func_company_brand before company_hierarchy_pdl_match)

1. Company
   func_is_broken_pdl_company.sql          predicate + partial index + sweep
     -> broken_pdl_company_apply.sql       preview + DELETE templates (company, experience)
   company_hierarchy_load.sql              optional; needs data/company_hierarchy.csv
     -> company_hierarchy_pdl_match.sql
     -> scripts/company_hierarchy_pdl_cleaner.py   (PDL Cleaner API on residual no_match)
     -> company_hierarchy_edges.sql

2. Person
   invalid_names_filter.sql
   person_dedup_on_linkedin.sql

3. Experience                              (after broken-company removal)
   experience_duplicate.sql

4. Education
   degree_family.sql
     -> pe_norm.sql
     -> education_null_degree_rescue.sql
     -> education_duplicate.sql
     -> education_is_keep.sql

5. School
   school_canonical_rollup.sql
```

Why this order: broken PDL company canonicals are removed before experience dedup so bogus employers don't form duplicate clusters; `pe_norm` precomputes the degree-family key that the rescue and the education checks read; the null-degree rescue is computed before education dedup so that (once it is wired into the cluster key — see [open questions](#open-questions)) rescued rows land in their siblings' clusters; `education_is_keep` needs the clusters to exist. `school_canonical_rollup.sql` defines its own helper function and depends on nothing else here.

## Routines

Each entry: what it fixes, then inputs → outputs. All outputs land in `cleansing_rad`.

### 1. Normalization functions

Row-level, string-to-string, deterministic. All are `IMMUTABLE STRICT` Postgres functions in `cleansing_rad` with a `CHECK` query of sample inputs at the bottom of the file.

| File | Function | What it does |
|---|---|---|
| [`func_normalize_company_name.sql`](func_normalize_company_name.sql) | `func_normalize_company_name(text)` | Unicode NFC, typographic punctuation → ASCII, trim, collapse whitespace. Display casing preserved. |
| [`func_company_brand.sql`](func_company_brand.sql) | `func_company_brand(text)` | Lowercases and strips corporate-entity suffixes (`LLC`, `Inc`, `Ltd`, `PLC`, `GmbH`, `AG`, `Pty Ltd`, `S.A.`, …) to get the distinctive brand core used for name matching. |
| [`func_normalize_person_name.sql`](func_normalize_person_name.sql) | `func_normalize_person_name(text)` | NFC + punctuation fold + whitespace; strips credential suffixes (`PhD`, `MD`, `MBA`, `Esq.`, …) and honorific prefixes (`Dr.`, `Mr.`, `Rev.`, …); keeps generational suffixes (`Jr.`, `III`). |
| [`func_normalize_title.sql`](func_normalize_title.sql) | `func_normalize_title(text)` | Lowercase, trim, collapse whitespace — the comparison form of a job title. |
| [`func_normalize_linkedin_url.sql`](func_normalize_linkedin_url.sql) | `func_normalize_linkedin_url(text)` | NFC + punctuation fold, lowercase, strip protocol, `www.` and trailing slash, so URL variants compare equal. |
| [`func_linkedin_slug.sql`](func_linkedin_slug.sql) | `func_linkedin_slug(text)` | Extracts the company slug after `/company/` (drops query string, fragment, trailing slash). |
| [`func_normalize_location.sql`](func_normalize_location.sql) | `func_normalize_location(text)` | NFC (accented place names often arrive decomposed), punctuation fold, trim, collapse whitespace for location display strings. |
| [`func_normalize_prose.sql`](func_normalize_prose.sql) | `func_normalize_prose(text)` | Unicode + whitespace + punctuation cleanup for free text (`headline`, `summary`); preserves paragraph breaks. Translation to English is a separate, deferred design. |

### 2. Company routines

**Broken PDL company canonicals** — PDL sometimes canonicalizes a role, occupation or placeholder that people typed into their LinkedIn "company" field ("self-employed", "consultant", "n/a", …) into a single bogus company entity with thousands of attributed employees.

- [`func_is_broken_pdl_company.sql`](func_is_broken_pdl_company.sql) — predicate `func_is_broken_pdl_company(name)` (exact match of the normalized name against a curated list of occupation / role / employment-status / placeholder tokens), a partial index on `integration.company` for the sweep, and V1–V4 sizing queries.
  - In: `integration.company`, `integration.experience`. Out: function + partial index; the V-queries report how many broken companies exist and how many experience rows (and persons) point at them — a few hundred companies and tens of thousands of experience rows on a full delivery.
- [`broken_pdl_company_apply.sql`](broken_pdl_company_apply.sql) — preview SELECTs and commented-out DELETE templates for the broken companies and their experience rows, minus an inline known-exception list (real companies whose name happens to be a token). Uses the `ARRAY(subquery) + = ANY` shape so the delete is fast on a large `integration.experience`.
  - In: `integration.company`, `integration.experience`. Out: deletes (when uncommented).

**Company hierarchy** (optional) — loads a user-supplied company hierarchy spreadsheet (parents, subsidiaries, acquired companies, predecessors, regional offices; up to 6 levels), matches each company to a PDL company id, and emits parent → child edges that can later feed `integration.company_affiliation`. Input format and preparation: [`data/README.md`](data/README.md). A synthetic example is at [`data/company_hierarchy.example.csv`](data/company_hierarchy.example.csv).

- [`company_hierarchy_load.sql`](company_hierarchy_load.sql) — loads `data/company_hierarchy.csv`, moves comments typed into `child_5` to `notes`, and forward-fills each row's ancestor chain so every row carries its full root-to-self path.
  - In: CSV. Out: `cleansing_rad.company_hierarchy`.
- [`company_hierarchy_pdl_match.sql`](company_hierarchy_pdl_match.sql) — one row per distinct company name; tier 1 exact brand match (`func_company_brand` on both sides), tier 2 substring brand match; tiebreak on most experience rows → shortest name → `pdl_company_id`. Records the implementation decision still open for companies PDL doesn't hold.
  - In: `cleansing_rad.company_hierarchy`, `integration.company`, `integration.experience`. Out: `cleansing_rad.company_brand_lookup`, `cleansing_rad.company_hierarchy_pdl_match`, view `cleansing_rad.company_hierarchy_with_pdl_ids`.
- [`scripts/company_hierarchy_pdl_cleaner.py`](scripts/company_hierarchy_pdl_cleaner.py) — tier 3: calls PDL `/v5/company/clean` by name for rows still `no_match`, stores status + response for audit, sets `match_tier = 'cleaner_api'`, and backfills `company_id` where the returned id exists locally. Dry run by default; pass `--execute` to call PDL (also `--refresh-all`, `--rpm`).
  - In/Out: `cleansing_rad.company_hierarchy_pdl_match`.
- [`company_hierarchy_edges.sql`](company_hierarchy_edges.sql) — long-form edge table, one row per direct parent → child relationship, PDL ids and `integration.company` ids on both sides, plus the root company of each branch.
  - In: `company_hierarchy`, `company_hierarchy_pdl_match`. Out: `cleansing_rad.company_hierarchy_edges`.

### 3. Person routines

- [`invalid_names_filter.sql`](invalid_names_filter.sql) — splits persons into valid / invalid names after `func_normalize_person_name`. Invalid = first/last/full name is a credential or placeholder (`phd`, `admin`, `test`, `n/a`, `unknown`, `the company`, …) or contains non-Latin script characters. Flags kept on the invalid side for review.
  - In: `integration.person`. Out: `cleansing_rad.person_valid_name`, `cleansing_rad.person_invalid_name`.
- [`person_dedup_on_linkedin.sql`](person_dedup_on_linkedin.sql) — when several person rows share a LinkedIn URL (case-insensitive), keeps the one with the freshest PDL signal (`job_last_changed` / `job_last_verified` / `location_last_updated`), `pdl_id` as tiebreak. Persons without a LinkedIn URL pass through unchanged.
  - In: `integration.person`. Out: `cleansing_rad.person_dedup_on_linkedin` (the surviving person rows).

### 4. Experience routines

- [`experience_duplicate.sql`](experience_duplicate.sql) — finds duplicate employment records (same person + same company + same normalized title, 2+ rows) and labels each cluster with a compound `dup_cluster_status` built in fixed order from `Null Company` / `Null Title` / `Exact Duplicate` / `Superset/Subset` / `Overlap Tenure` / `Disjoined Tenure`. Computes a per-row `record_completeness_score`; `is_keep` is a placeholder (row-level winner rules are the next pass). V-A/V-B give the taxonomy distribution and one sample cluster per status; V-C repeats them for a single job-title sub-role and dumps every cluster for a chosen status.
  - In: `integration.experience`, `ref.job_title_class/role/subrole`. Out: `cleansing_rad.experience_duplicate`.

### 5. Education routines

- [`degree_family.sql`](degree_family.sql) — PDL emits degrees from a small controlled vocabulary but at varying specificity for the same education (`["masters"]` vs `["master of science","masters"]`). Maps every distinct degree string to a family (`bachelors` / `masters` / `doctorates` / `associates` / `other`) by prefix rule so both forms hash to the same cluster key.
  - In: `integration.person_education`. Out: `cleansing_rad.degree_family`.
- [`pe_norm.sql`](pe_norm.sql) — narrow, indexed projection of `integration.person_education` with precomputed `degrees_family_norm`, degree-family and majors counts, and a completeness score. A performance sidecar so the rescue and the education checks run in seconds; rebuild it whenever `integration.person_education` or `degree_family` changes.
  - In: `integration.person_education`, `degree_family`. Out: `cleansing_rad.pe_norm`.
- [`education_null_degree_rescue.sql`](education_null_degree_rescue.sql) — fills the PDL gap where one row has `degrees = []` while a sibling (same person + school + matching years) has real degrees. Three confidence tiers: **high** (start and end year both match), **medium** (one year matches, the other side is NULL), **low** (years overlap only).
  - In: `pe_norm`, `integration.person_education`. Out: `cleansing_rad.education_null_degree_rescue` (`education_id → source_education_id → filled_degrees_family_norm`, tier).
- [`education_duplicate.sql`](education_duplicate.sql) — same taxonomy as `experience_duplicate` (`Null School` / `Null Degrees` / `Exact Duplicate` / `Superset/Subset` / `Overlap Tenure` / `Disjoined Tenure`) on cluster key `(person_id, school_id, degrees_family_norm)`. Majors and years are deliberately not in the key (most majors-differ pairs are subset/superset variants). V-D measures the remaining "canonicalization headroom"; V-G/V-H profile multi-family and multi-major rows.
  - In: `pe_norm`, `degree_family`, `integration.person_education`. Out: `cleansing_rad.education_duplicate`.
- [`education_is_keep.sql`](education_is_keep.sql) — an `UPDATE` that marks one winner per education cluster (`is_keep = true`, the rest `false`), ranked by `record_completeness_score` → tenure width → majors/degrees/minors array length → summary length → `education_id`.
  - In/Out: `cleansing_rad.education_duplicate.is_keep`.

### 6. School routines

- [`school_canonical_rollup.sql`](school_canonical_rollup.sql) — rolls school-name variants up to a canonical school on key `(domain, type, subunit)`. `func_school_subunit(domain, type, name)` splits one institution's domain into academic sub-schools (law / business / medical / engineering / …) and separate buckets for military, K-12, community-college, training, extension, online and summer programs. Centers / institutes, alumni chapters, student organizations and conferences keep their own identity (one canonical per row). Schools without a domain are their own canonical.
  - In: `integration.school`, `integration.person_education`. Out: function `cleansing_rad.func_school_subunit`, tables `cleansing_rad.school_canonical` and `cleansing_rad.school_canonical_map` (`school_id → canonical`).

## Path into the pipeline

Each artifact becomes one of three things in the pipeline design ([`../design/21_cleansing_layer_design.md`](../design/21_cleansing_layer_design.md)):

- **Row-level, string-to-string, deterministic** → **Postgres function** (Flyway `R__` migration).
- **Set-level, produces a table** → **dbt model** in the `_cleaned` staging tier.
- **External API call** → **Python task** on the generic PDL caller ([`../design/18_pdl_api_generic_caller.md`](../design/18_pdl_api_generic_caller.md)).

### Postgres functions (Flyway `R__func_*.sql`)

Real functions, not dbt macros: a macro is a compile-time text template and can't back an expression index.

| R&D file | Pipeline shape |
|---|---|
| `func_normalize_company_name.sql` | `R__func_normalize_company_name.sql` |
| `func_company_brand.sql` | `R__func_company_brand.sql` |
| `func_normalize_person_name.sql` | `R__func_normalize_person_name.sql` |
| `func_normalize_title.sql` | `R__func_normalize_title.sql` |
| `func_normalize_linkedin_url.sql` | `R__func_normalize_linkedin_url.sql` |
| `func_linkedin_slug.sql` | `R__func_linkedin_slug.sql` |
| `func_normalize_location.sql` | `R__func_normalize_location.sql` |
| `func_normalize_prose.sql` | `R__func_normalize_prose.sql` |
| predicate in `func_is_broken_pdl_company.sql` | `R__func_is_broken_pdl_company.sql` |
| predicate in `invalid_names_filter.sql` | `R__func_is_invalid_name.sql` |

### Filters: two patterns

**Pattern A — row-level boolean classifier.** When the whole rule is a boolean function of one row's columns (no joins, aggregations or tiebreaks), split the file: the **predicate** becomes a Postgres function; the **apply** becomes `WHERE NOT is_<predicate>(...)` inline in the `_cleaned` model.

```sql
-- R__func_is_invalid_name.sql (shape)
create or replace function cleansing_rad.func_is_invalid_name(nm text)
  returns bool language sql immutable strict as
$$
  select lower(nm) ~ '^(admin|test|unknown|n/?a|none|...)$'
      or nm ~ '[<non-Latin ranges>]';
$$;

-- models/staging/pdl_person/pdl_person_cleaned.sql (shape)
select ...
  from {{ ref('pdl_person_unique') }}
 where not cleansing_rad.func_is_invalid_name(first_name)
   and not cleansing_rad.func_is_invalid_name(last_name);
```

Why split: the same predicate is wanted on other columns (experience contact names, any future source's name fields) — a copied WHERE clause is exactly the drift this prevents. Uses Pattern A: `invalid_names_filter.sql`, `func_is_broken_pdl_company.sql` + `broken_pdl_company_apply.sql`.

**Pattern B — set-level operation.** Joins, aggregations, `DISTINCT ON`, tiebreaks → the whole file becomes a `_cleaned` dbt model. Uses Pattern B: `person_dedup_on_linkedin.sql`, `experience_duplicate.sql`, the education chain, `school_canonical_rollup.sql`, the company-hierarchy chain.

### dbt models (staging `_cleaned` tier)

| R&D file | Pipeline shape (approximate) |
|---|---|
| `invalid_names_filter.sql` (apply) | `WHERE NOT func_is_invalid_name(...)` in the person `_cleaned` model |
| `broken_pdl_company_apply.sql` (apply) | `WHERE NOT func_is_broken_pdl_company(...)` in the company / experience `_cleaned` models |
| `person_dedup_on_linkedin.sql` | `models/staging/pdl_person/pdl_person_deduped.sql` |
| `experience_duplicate.sql` | experience `_cleaned` model + collapse in `_staged` |
| `degree_family.sql` | `ref.degree_family` seed from a reviewed CSV — stable and human-reviewable, not re-derived from the corpus each run |
| `pe_norm.sql` | folded into the education `_cleaned` model (precomputed columns become CTEs) |
| `education_null_degree_rescue.sql` | education `_cleaned` model step that runs before dedup and feeds the cluster key via `COALESCE` |
| `education_duplicate.sql` + `education_is_keep.sql` | one education `_cleaned` model: dedup + winner selection + canonical field merge |
| `school_canonical_rollup.sql` | school `_cleaned` model (`school_canonical` + map) |
| `company_hierarchy_load.sql` | dbt seed (the hierarchy CSV) + `_cleaned` model that forward-fills |
| `company_hierarchy_pdl_match.sql`, `company_hierarchy_edges.sql` | company `_cleaned` models feeding `integration.company_affiliation` |

### Python tasks (API callers)

| R&D file | Pipeline shape |
|---|---|
| `scripts/company_hierarchy_pdl_cleaner.py` | a `processing/pdl_api` company-cleaner input (hierarchy names enqueued into `pdl_api.company_input_list`), responses landing in `pdl_api.company_cleaner_call` for a `_cleaned` model to read |

### `integration.*` builds last

`integration.*` reads only from `_cleaned` outputs and never applies cleansing itself — the inverse of the R&D shape here, which reads `integration.*` for exploration.

## Open questions

- **`experience_duplicate.is_keep`** — populated as NULL. Row-level winner/loser rules per `dup_cluster_status` shape are not designed yet.
- **`is_primary` excluded from completeness scoring** — it would bias toward current jobs and drop historical roles. Revisit if the winner-picker is redesigned.
- **`experience_duplicate` cluster key `(person_id, company_id, normalized title)`** — null-company and real-company rows for the same `(person, title)` land in separate clusters. Merging them means dropping `company_id` from the partition, which moves Null-Company semantics from cluster level to row level.
- **Broken-company exception list** — inline in `broken_pdl_company_apply.sql`. If it grows past a handful of entries, move it to a ref table or manifest file.
- **Education same-year residual** — after the rescue, the large majority of same-person + same-school + same-years pairs share a cluster. The remainder are mostly bundled multi-family rows (`["bachelors","masters", …]`) vs single-family siblings; no clean rule separates "same education, different granularity" from a genuine dual-degree program. Accepted as open.
- **Rescue not yet in the education cluster key** — `education_null_degree_rescue` is a sidecar; the rescued rows still sit in `Null Degrees` clusters. Next rebuild: cluster on `COALESCE(pe_norm.degrees_family_norm, rescue.filled_degrees_family_norm)`, then re-run `education_is_keep`.
- **Low-confidence rescues** are the majority of all rescues. Consider dropping the low tier if bad fills are reported; its contribution to cluster match rate is bounded.
- **Education canonical field merge** — `education_is_keep` marks the winner row only. The `_cleaned` model must decide what to take from losers (likely union `majors[]`, keep the winner's `degrees[]`, drop losers' summary / GPA).
- **Company hierarchy, unmatched companies** — create them in `integration.company` with `pdl_company_id = NULL`, or keep only matched-both-sides edges, or keep them in `cleansing_rad` only. See the IMPLEMENTATION STEP block in `company_hierarchy_pdl_match.sql`.

## Directory layout

```
pdl_data_cleansing/
├── README.md                               this file
├── func_*.sql                              normalization functions + broken-company predicate
├── broken_pdl_company_apply.sql            broken PDL company preview + DELETE templates
├── company_hierarchy_load.sql              company hierarchy: load + forward-fill
├── company_hierarchy_pdl_match.sql         company hierarchy: match names to PDL ids
├── company_hierarchy_edges.sql             company hierarchy: parent → child edges
├── invalid_names_filter.sql                person name validity split
├── person_dedup_on_linkedin.sql            person dedup on LinkedIn URL
├── experience_duplicate.sql                employment duplicate taxonomy
├── degree_family.sql                       degree → family map
├── pe_norm.sql                             education row-norm performance sidecar
├── education_null_degree_rescue.sql        null-degrees fill from siblings
├── education_duplicate.sql                 education duplicate taxonomy
├── education_is_keep.sql                   winner row per education cluster
├── school_canonical_rollup.sql             school canonicalization
├── data/
│   ├── README.md                           input formats + preparation
│   └── company_hierarchy.example.csv       synthetic hierarchy example
└── scripts/
    └── company_hierarchy_pdl_cleaner.py    PDL Cleaner API pass for the hierarchy match
```
