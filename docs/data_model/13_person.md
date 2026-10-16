# Person Schema — Normalized Relational Model

**Status:** Implemented (`processing/dbt/models/integration/`). The §11 views are proposals, not created; `catalog.person_key_map` (§7) is reserved and not populated.
**Source:** `raw.pdl_person` — PDL Person bulk deliveries (see [doc 14 — Sources](14_sources.md)).
**PDL schema docs:** https://docs.peopledatalabs.com/docs/person-schema
**Companion docs:**
- [doc 08 — Company schema](08_company.md) — `integration.company` (referenced by `experience.company_id`)
- [doc 10 — Canonical reference tables](10_reference_tables.md) — full `ref.*` catalog (loader-discovered, no seeding)
- [doc 12 — Location & address schema](12_location.md) — `ref.country` / `state_province` / `city` / `metro` / `location` hierarchy (address data lives as inline scalars on `integration.person` and `integration.company` per V20/V24 Option C — no separate address table)
- [requirements/01 — Pipeline requirements](../requirements/01_pipeline_requirements.md) §2 — stateless content rebuild + stateful identity ledger
- [doc 14 — Sources](14_sources.md) — PDL Person bulk + PDL API, per-row / per-edge `source` attribution
- [design/02 — Pipeline design](../design/02_pipeline_design.md) — pipeline stages + catalog ledger

---

## 1. Purpose

Model the conformed Person entity, fully parsed and harmonized from PDL
person snapshots, plus the satellite entities and dimensions that hang off
it: experience, education, school, social profiles, multi-valued attribute
sets (skills, interests, languages, etc.), and locations.

**Scope:** the full person side of the integration schema — every column
we consume from PDL Person. PDL is the only source; see
[doc 14](14_sources.md).

This is the design contract; the DDL is in `modeling/dbml/integration.dbml`
and the dbt models in `processing/dbt/models/integration/`.

---

## 2. Design Principles

1. **Two schemas — `ref` for canonical dimensions, `integration` for
   conformed entities.** Same split as docs 08, 10, 12. `ref.*` holds
   country/state_province/city/metro/location, industry/industry_v2,
   job_title_class/role/subrole, seniority_level, skill, interest,
   language. `integration.*` holds person, company, school, experience,
   person_education, and all PDL-fed bridge tables (address scalars live
   inline on the entity tables per V20/V24 — no separate
   `integration.address`).

2. **Stateless rebuild — including `ref.*`.** Every pipeline run rebuilds
   `raw.pdl_person`, `ref.*`, and `integration.*` from current source data.
   All ref rows are loader-discovered from PDL per [ADR-0011](../decisions/0011-loader-discovered-ref-tables.md)
   (no seeded ref layer). **Surrogate bigint IDs in `ref.*` and
   `integration.*` are not stable across rebuilds** — downstream consumers
   must query by natural keys (`pdl_id`, `country.name_lc`, etc.), never by
   stored surrogate IDs. The only stateful component is the catalog
   identity ledger (see §7).

3. **Bigint surrogate PK + `pdl_id text UNIQUE NOT NULL` natural key.**
   `integration.person.id` is `bigint` PK; dbt-computed via
   `ROW_NUMBER() OVER (ORDER BY pdl_id)` per ADR-0010 (V20 dropped
   `GENERATED ALWAYS AS IDENTITY` across `integration.*`). PDL's opaque
   id lives in `pdl_id`. Same shape for `company.pdl_company_id` and
   `school.pdl_id`. All FKs reference the surrogate.

4. **Cross-system identifiers live in the ledger, not on the entity.**
   Any cross-source or downstream-system ID mappings belong in
   `catalog.person_key_map` per requirements/01 §4.2. `integration.person`
   carries attributes only; this keeps the integration table rebuildable.

5. **Multi-valued PDL fields become junctions; not jsonb on the entity.**
   Same as company. Skills, interests, languages, locations, countries,
   state_provinces — all junction tables keyed by `(person_id, …)`.
   Exceptions: `degrees` / `majors` / `minors` on `person_education`
   stay jsonb (per-education-entry arrays, no useful cross-entity
   grouping). Tables that V16 dropped because their PDL source was
   empty or bool-placeholders: `person_name_alias`,
   `person_certification`, `person_social_network`.

6. **Title text + 3 individual classification FKs, not a `ref.title` table.**
   Raw PDL titles vary too much to canonicalize into a lookup table.
   `experience.title text` (btree indexed) handles "title contains 'engineer'";
   the three independent FKs `title_class_id` / `title_role_id` /
   `title_sub_role_id` (each → its own ref table) handle "all software
   engineers regardless of exact title" via composable joins. See §4.2.

7. **Source provenance.** PDL is the only source, but the model
   keeps provenance columns so another source could be added later
   without reshaping tables: `ref.industry.source_type` (always `'pdl'`),
   `integration.experience_industry.source` (per-edge attestation, always
   `'pdl'`), and `integration.company.source` (which PDL feed produced the
   row). See [doc 14](14_sources.md).

---

## 3. Entity-Relationship Overview

`integration.person` is the central entity. Locations, classifications,
and multi-valued attributes hang off in three patterns:

```
                ╔════════════════════════════════════════════════════════════╗
                ║                  integration.person                        ║
                ║  PK  id              bigint, surrogate                     ║
                ║  UQ  pdl_id          PDL natural key                       ║
                ║  FK  industry_id     → ref.industry.id                     ║
                ║  FK  location_id     → ref.location.id                     ║
                ║      latitude        numeric(9,6) scalar  (V20 Option C)   ║
                ║      longitude       numeric(9,6) scalar                   ║
                ║      postal_code     text scalar                           ║
                ╚════════════════════════════════════════════════════════════╝
                                  │
   ┌──── 1:N ──────────────────┬──┴────────────────────────────────┐
   │                            │                                   │
   ▼                            ▼                                   ▼
 integration.experience    integration.person_education       junctions
   FK person_id              FK person_id                       (PDL)
   FK company_id             FK school_id                     person_skill
   FK title_class_id         (degrees/majors/minors jsonb)    person_interest
   FK title_role_id          start_year / end_year int4       person_language
   FK title_sub_role_id
   title text                                                  person_country
   start_year / end_year                                       person_state_province
                                                               person_location  (multi-locations)
   ↓ 1:N junctions
   experience_location
   experience_industry
   experience_seniority_level

 integration.school                integration.company
   FK location_id                    FK location_id
   (no address scalars —             latitude / longitude / postal_code
   PDL school has coarse-grain       street_address / address_line_2
   location only, no street)         scalars (V24 Option C — inline,
                                     no separate company_hq_address table)

  Reference tables (ref.*):
    country · state_province · city · metro · continent · location  (doc 12)
    industry · industry_v2
    job_title_class · job_title_role · job_title_subrole  (3 independent ref tables, V25 Option E)
    seniority_level
    skill · interest · language
    pdl_relationship  (company affiliations — doc 08)
```

**Address shape — inline scalars on entity tables** (V20 for person,
V24 for company). PDL emits each entity's address as a single object
per source row, empirically 1:1 with the entity. There's no separate
`integration.address` / `integration.company_hq_address` table —
those existed in V6-V20 / V21-V23 and were dropped once the cardinality
was confirmed structurally. The "address" is just scalar columns on
the entity. See [doc 12](12_location.md) for the location hierarchy
(which remains the canonical place reference).

---

## 4. Table-by-Table Specification

Notation: `PK` primary key, `FK` foreign key, `*` not-null. Types are
PostgreSQL flavor. Every table carries `timestamp_created timestamptz
DEFAULT now()` and `timestamp_modified timestamptz DEFAULT now()` unless
noted — omitted from the column lists below for brevity. The
loader-rebuild model means these timestamps reflect when the *current*
rebuild created/touched the row, not historical creation.

### 4.1 `integration.person`

| Column                  | Type           | Notes                                                                    |
|-------------------------|----------------|--------------------------------------------------------------------------|
| `id` *                  | `bigint`       | PK. dbt-computed via ROW_NUMBER (ADR-0010 — IDENTITY dropped on integration.* in V20). |
| `pdl_id` *              | `text`         | **UNIQUE NOT NULL**. PDL natural key (alias-resolved at staging).        |
| `first_name`            | `text`         |                                                                          |
| `middle_name`           | `text`         |                                                                          |
| `middle_initial`        | `text`         | Length 1                                                                 |
| `last_name`             | `text`         |                                                                          |
| `last_initial`          | `text`         | Length 1                                                                 |
| `full_name`             | `text`         | PDL concatenated                                                         |
| `headline`              | `text`         | PDL `headline`                                                           |
| `summary`               | `text`         | PDL `summary`                                                            |
| `industry_id`           | `bigint`       | FK → `ref.industry.id` (PDL `industry`)                                  |
| `linkedin_id`           | `text`         |                                                                          |
| `linkedin_url`          | `text`         |                                                                          |
| `linkedin_username`     | `text`         |                                                                          |
| `location_id`           | `bigint`       | FK → `ref.location.id` (coarse-grain place hierarchy)                    |
| `latitude`              | `numeric(9,6)` | Parsed from PDL `location.geo`. **V20 Option C — inline scalar**, no person.address_id FK. |
| `longitude`             | `numeric(9,6)` | Parsed from PDL `location.geo`.                                          |
| `postal_code`           | `text`         | PDL `location.postal_code`.                                              |
| `sex`                   | `text`         |                                                                          |
| `work_email`            | `text`         | PII-allowed per §6.1.                                                    |
| `job_last_changed`      | `timestamptz`  | PDL freshness signal — when current job last changed (populated on most records). |
| `job_last_verified`     | `timestamptz`  | PDL freshness signal — when PDL last verified current employment.        |
| `location_last_updated` | `timestamptz`  | PDL freshness signal — when PDL last updated location info.              |

**Indexes:** PK on `id`; `UNIQUE (pdl_id)`; btree on `full_name`,
`linkedin_id`, `linkedin_url`, `industry_id`, `location_id`. 7 indexes
total.

**Not on this table** (intentional, per design decisions):
- Cross-system identifiers — live in `catalog.person_key_map` (§7).
- `birth_date`, `birth_year`, `emails[]`, `personal_emails[]`, `mobile_phone` — PII or PDL bool-placeholders, not stored. (V16 dropped `mobile_phone` after verifying it's a bool-placeholder on the subscription tier this pipeline uses.)
- `linkedin_connections`, `inferred_years_experience`, `dataset_version`, `first_seen`, `num_sources`, `num_records` — V16 dropped after verification (never populated in the profiled delivery; `dataset_version` is per-delivery metadata, see [doc 14 §2](14_sources.md)).
- `address_id` (FK to a separate address table) — V20 chose inline scalar lat/long/postal_code instead (Option C); no separate person address table exists.
- `profiles[]` networks (`facebook_*`, `twitter_*`, `github_*`) — V16 dropped (PDL bool-placeholders on this tier).

### 4.2 `integration.experience`

| Column                | Type     | Notes                                                                            |
|-----------------------|----------|----------------------------------------------------------------------------------|
| `id` *                | `bigint` | PK. dbt-computed via ROW_NUMBER (ADR-0010).                                      |
| `person_id` *         | `bigint` | FK → `integration.person.id`                                                     |
| `experience_idx`      | `int4`   | PDL array position within `$.experience[*]`, carried from staging. `(person_id, experience_idx)` is unique per row and indexed — JOIN key from per-experience junction models (experience_location/_industry/_seniority_level). Added V27. |
| `company_id`          | `bigint` | FK → `integration.company.id` (NULL when PDL emits `experience` with no `company.id` — a sizeable minority of rows) |
| `start_year`          | `int4`   | PDL `experience.start_date` year (year-only precision).              |
| `end_year`            | `int4`   | PDL `experience.end_date` year. NULL = current position.                         |
| `title`               | `text`   | **Raw PDL `experience.title.name`**. Btree indexed (V6). Trigram deferred — add via additive migration when a consumer query demands substring/fuzzy search. |
| `title_class_id`      | `bigint` | FK → `ref.job_title_class.id`. Nullable independently of the other two title FKs. |
| `title_role_id`       | `bigint` | FK → `ref.job_title_role.id`. Nullable independently.                            |
| `title_sub_role_id`   | `bigint` | FK → `ref.job_title_subrole.id`. Nullable independently. Most frequently NULL of the three. |
| `is_primary`          | `bool`   | PDL `experience.is_primary` — true for the current role. Not indexed (V25 dropped idx_experience_is_primary; low-cardinality bool indexes don't pay back). |
| `summary`             | `text`   | PDL `experience.summary`                                                          |

**Indexes:** PK on `id` + btree on `person_id`, `company_id`, `title`, `(person_id, experience_idx)`. 5 indexes total.

**Title classification — 3 independent FKs (V25 Option E).** PDL emits
`title.class`, `title.role`, `title.sub_role` as 3 independent canonical
enum strings. A noticeable share of experiences emit class+role with NULL
sub_role; a composite FK couldn't represent these partials (the
prior `ref.job_title_classification` required all 3 NOT NULL). V25
replaced the composite FK with 3 individual FKs to the existing
single-column ref tables (`ref.job_title_class` / `ref.job_title_role`
/ `ref.job_title_subrole`). Each FK is nullable independently; partials
are preserved.

For search:
- **By exact / fuzzy title text** → `WHERE title ILIKE '%engineer%'` (btree only; a trigram index is a future additive migration if consumer queries demand it).
- **By canonical role** → `JOIN ref.job_title_role rl ON rl.id = e.title_role_id WHERE rl.name = 'software_engineer'`.
- **By class + role combo** → `JOIN ref.job_title_class cls ... JOIN ref.job_title_role rl ... WHERE cls.name = 'engineering' AND rl.name = 'software_engineer'`.

### 4.3 `integration.person_education`

PDL `education[]` array — per-education-entry attributes.

| Column          | Type          | Notes                                                  |
|-----------------|---------------|--------------------------------------------------------|
| `id` *          | `bigint`      | PK. dbt-computed via ROW_NUMBER (ADR-0010).            |
| `person_id` *   | `bigint`      | FK → `integration.person.id`                           |
| `school_id`     | `bigint`      | FK → `integration.school.id`                           |
| `start_year`    | `int4`        | Year education started (4-digit). V26 switched from `start_date timestamptz` — PDL emits year-only precision, mirrors V25's experience pivot. |
| `end_year`      | `int4`        | Year education ended (4-digit). NULL when PDL emitted no end_date. V26 switched from `end_date timestamptz`. |
| `degrees`       | `jsonb`       | PDL `education[].degrees` — array of strings           |
| `majors`        | `jsonb`       | PDL `education[].majors`                               |
| `minors`        | `jsonb`       | PDL `education[].minors`                               |
| `gpa`           | `numeric(4,2)`|                                                        |
| `summary`       | `text`        | PDL `education[].summary`                              |

**Indexes:** btree on `person_id`, `school_id`.

**Why jsonb for degrees/majors/minors:** these are per-education arrays
that don't merit dedup across entries (a person can have multiple "BS"
entries from different schools; no canonical cross-entity grouping by
degree name in scope). Cheaper than three more junction
tables. Promote to junctions later if cross-entity analysis becomes a use
case.

### 4.4 `integration.school`

PDL `education[].school` sub-object.

| Column            | Type     | Notes                                                                                   |
|-------------------|----------|-----------------------------------------------------------------------------------------|
| `id` *            | `bigint` | PK. dbt-computed via ROW_NUMBER (ADR-0010).                                             |
| `pdl_id` *        | `text`   | **UNIQUE NOT NULL**. PDL natural key for the school.                                    |
| `name`            | `text`   |                                                                                         |
| `domain`          | `text`   |                                                                                         |
| `type`            | `text`   | `university` \| `secondary school` \| etc. (PDL canon)                                  |
| `website`         | `text`   |                                                                                         |
| `linkedin_id`     | `text`   |                                                                                         |
| `linkedin_url`    | `text`   |                                                                                         |
| `facebook_url`    | `text`   |                                                                                         |
| `twitter_url`     | `text`   |                                                                                         |
| `location_id`     | `bigint` | FK → `ref.location.id`. PDL school location is **coarse-grain only** (continent/country/region/locality — no street, no metro). See doc 12 §5. |

**No `address_id`** — PDL doesn't emit street-level data for schools.
Adding it would mean the column is always NULL.

**Indexes:** `UNIQUE (pdl_id)`; btree on `name`, `domain`, `linkedin_id`, `location_id`.

### 4.5 `integration.company`

Full spec in [doc 08](08_company.md). Person-tier data populates the
columns PDL emits on `experience[].company`; PDL Company Enrichment (V28)
fills the rest via the LEFT JOIN + COALESCE merge.
`integration.experience.company_id` FKs into this table.

### 4.6 No separate `integration.address` table

V6 baseline created `integration.address` as a shared per-entity
street-level table. The V20→V24 design evolution dropped it entirely
once empirical 1:1 cardinality with the parent entities was verified:

- V20: `integration.person` inlined scalar `latitude / longitude /
  postal_code` directly (Option C); dropped `person.address_id`.
  PDL person tier has no street-level data on this subscription tier.
- V21: renamed `integration.address` → `integration.company_hq_address`
  (the table was effectively company-HQ-only by that point).
- V24: dropped the renamed table entirely and inlined scalars on
  `integration.company` too (latitude / longitude / postal_code /
  street_address / address_line_2). Every company in a profiled full
  delivery had exactly one distinct address across all referencing experience rows
  (PDL emits the canonical company sub-object per occurrence per
  [doc 08](08_company.md) §6). Separate table was pure indirection.

**Where address-equivalent data lives now**:
- `integration.person.{latitude, longitude, postal_code}` — V20 Option C
- `integration.company.{latitude, longitude, postal_code, street_address, address_line_2}` — V24 Option C
- `integration.school` — no street-level data; `location_id` FK only (PDL schools are coarse-grain only)

The location hierarchy itself (`ref.location` → ref.country / state_province / city / metro) remains the canonical place reference. See [doc 12](12_location.md).

### 4.7 `integration.experience_location`

PDL `experience[].location_names[]` — junction (M:N) between an
experience and the locations PDL associates with it.

| Column           | Type     | Notes                                            |
|------------------|----------|--------------------------------------------------|
| `experience_id` *| `bigint` | PK part, FK → `integration.experience.id`        |
| `location_id` *  | `bigint` | PK part, FK → `ref.location.id`                  |

### 4.8 `integration.experience_industry`

Industries attested per experience role. PDL emits a single
`company.industry` per experience, so there is one row per
experience whose company carries an industry. The table is a junction
(not a scalar FK on `experience`) so that a future source could attest
additional industries for the same role.

| Column           | Type     | Notes                                            |
|------------------|----------|--------------------------------------------------|
| `experience_id` *| `bigint` | PK part, FK → `integration.experience.id`        |
| `industry_id` *  | `bigint` | PK part, FK → `ref.industry.id`                  |
| `source` *       | `text`   | Per-edge source attestation. Always `'pdl'`; see [doc 14](14_sources.md). |

### 4.9 `integration.experience_seniority_level`

PDL `experience[].title.levels[]` — a title can map to multiple levels
(e.g. `["manager", "director"]`).

| Column                 | Type     | Notes                                            |
|------------------------|----------|--------------------------------------------------|
| `experience_id` *      | `bigint` | PK part, FK → `integration.experience.id`        |
| `seniority_level_id` * | `bigint` | PK part, FK → `ref.seniority_level.id`           |

### 4.10 `integration.person_country`

PDL `countries[]` — derived set of all countries associated with the
person across their record.

| Column         | Type     | Notes                                            |
|----------------|----------|--------------------------------------------------|
| `person_id` *  | `bigint` | PK part, FK → `integration.person.id`            |
| `country_id` * | `bigint` | PK part, FK → `ref.country.id`                   |

### 4.11 `integration.person_state_province`

PDL `regions[]` — derived set of all regions associated with the person.

| Column                | Type     | Notes                                            |
|-----------------------|----------|--------------------------------------------------|
| `person_id` *         | `bigint` | PK part, FK → `integration.person.id`            |
| `state_province_id` * | `bigint` | PK part, FK → `ref.state_province.id`            |

### 4.12 `integration.person_location`

PDL `location_names[]` plus any other locations PDL associates with the
person — multi-valued.

| Column         | Type     | Notes                                            |
|----------------|----------|--------------------------------------------------|
| `person_id` *  | `bigint` | PK part, FK → `integration.person.id`            |
| `location_id` *| `bigint` | PK part, FK → `ref.location.id`                  |

### 4.13 `integration.person_skill` / `_interest` / `_language`

PDL `skills[]`, `interests[]`, `languages[]`.

```
person_skill     (person_id, skill_id)        PK both;  FK → ref.skill.id
person_interest  (person_id, interest_id)     PK both;  FK → ref.interest.id
person_language  (person_id, language_id)     PK both;  FK → ref.language.id
```

PDL `languages[]` carries proficiency (1-5); we drop it
(per-language proficiency isn't part of integration use cases). Add a
`proficiency int4` column to `person_language` if downstream needs it.

### 4.14 Tables that USED to exist here — V16 drops

Three person-attribute tables were dropped in V16 after empirical
verification that they had no source:

- `integration.person_social_network` — V16 dropped. PDL emits LinkedIn
  at the person scalar level (`integration.person.linkedin_*`); other
  social networks (`facebook_*`, `twitter_*`, `github_*`) were verified
  as bool-placeholders on this PDL subscription tier (no real values in
  a full delivery). Add the table
  back via additive migration if a future source emerges.
- `integration.person_name_alias` — V16 dropped. PDL `name_aliases[]`
  was never populated in a full delivery.
- `integration.person_certification` — V16 dropped. PDL
  `certifications[]` was dropped from staging in V10 (not delivered on
  this subscription tier).

---

## 5. Reference Tables (`ref.*`)

Full catalog of `ref.*` tables exercised by this schema. Place hierarchy
(country / state_province / city / metro / continent / location) is
specified in [doc 12](12_location.md). All others below.

### 5.1 Industry classifications

```
ref.industry      (id, name UNIQUE, source_type)     -- source_type always 'pdl'
ref.industry_v2   (id, name UNIQUE)                  -- PDL canonical v2 enum
```

### 5.2 Job-title hierarchy

```
ref.job_title_class    (id, name UNIQUE)  -- 'operations' | 'engineering' | …
ref.job_title_role     (id, name UNIQUE)  -- 'software_engineer' | …
ref.job_title_subrole  (id, name UNIQUE)  -- 'backend_engineer' | …
```

`integration.experience` has 3 independent FKs to these dimensions —
`title_class_id`, `title_role_id`, `title_sub_role_id` (V25 Option E).
Each is independently nullable, so PDL's partial classifications
(class+role with NULL sub_role) are preserved. There's no composite
`ref.job_title_classification` table — V25 dropped it (zero remaining
FK referrers; the composite couldn't represent partial PDL tuples
because it required all 3 NOT NULL).

For "all engineering-class software engineers regardless of sub_role":
```sql
SELECT e.*
FROM integration.experience    e
JOIN ref.job_title_class       cls ON cls.id = e.title_class_id
JOIN ref.job_title_role        rl  ON rl.id  = e.title_role_id
WHERE cls.name = 'engineering' AND rl.name  = 'software_engineer';
```

### 5.3 Seniority

```
ref.seniority_level  (id, name UNIQUE)   -- 'manager' | 'director' | 'cxo' | …
```

PDL `experience[].title.levels[]` maps to a junction
(`integration.experience_seniority_level`); one experience can have
multiple levels.

### 5.4 Personal-attribute dimensions

```
ref.skill     (id, name, type)              -- multi-valued, junctioned via person_skill
ref.interest  (id, name, type)              -- multi-valued, junctioned via person_interest
ref.language  (id, name UNIQUE)             -- multi-valued, junctioned via person_language (empty: PDL doesn't emit languages[] on this tier)
```

---

## 6. Column-Level PDL → Schema Mapping

Source: `raw.pdl_person`. dbt staging models extract, parse, dedupe; the
integration layer joins everything together and resolves FKs.

### 6.1 Person-level fields

| PDL field                     | Destination                                                       |
|-------------------------------|-------------------------------------------------------------------|
| `id`                          | `integration.person.pdl_id` (UNIQUE natural key)                  |
| `first_name`                  | `integration.person.first_name`                                   |
| `middle_name`                 | `integration.person.middle_name`                                  |
| `middle_initial`              | `integration.person.middle_initial`                               |
| `last_name`                   | `integration.person.last_name`                                    |
| `last_initial`                | `integration.person.last_initial`                                 |
| `full_name`                   | `integration.person.full_name`                                    |
| `name_aliases[]`              | Not persisted. V16 dropped — never populated in a full delivery. |
| `headline`                    | `integration.person.headline`                                     |
| `summary`                     | `integration.person.summary`                                      |
| `industry`                    | `integration.person.industry_id` (FK; resolve via `ref.industry`) |
| `linkedin_url` / `_id` / `_username` | `integration.person.linkedin_url` / `_id` / `_username`    |
| `linkedin_connections`        | Not persisted. V16 dropped (never populated on this subscription tier). |
| `sex`                         | `integration.person.sex`                                          |
| `work_email`                  | `integration.person.work_email`                                   |
| `job_last_changed` / `job_last_verified` / `location_last_updated` | `integration.person.{job_last_changed, job_last_verified, location_last_updated}` — real PDL freshness signals (populated on most records). |
| **`mobile_phone`**            | Not persisted. V16 dropped — PDL bool-placeholder on this subscription tier. |
| **`inferred_years_experience`** | Not persisted. V16 dropped (never populated).                   |
| **`dataset_version`**         | Not persisted on `integration.person` (uniform per delivery; see [doc 14 §2](14_sources.md)). |
| **`first_seen` / `num_sources` / `num_records`** | Not persisted. V16 dropped (keys absent from PDL JSON on this subscription tier). |
| **`birth_date` / `birth_year`** | Not persisted (PII + PDL bool-placeholders).        |
| **`emails[]` / `personal_emails[]` / `recommended_personal_email`** | Not persisted (PII).        |
| **`phone_numbers[]` / `phones[]`** | Not persisted (PII).                                          |
| **`profiles[]` / `facebook_*` / `twitter_*` / `github_*`** | Not persisted. V16 dropped from staging — PDL bool-placeholders on this subscription tier. LinkedIn is the only social network with real values; lives on `integration.person.linkedin_*`. |
| **`possible_*` arrays**       | Not persisted (low-confidence; stays in raw for resolution use).  |

### 6.2 Location

| PDL field                                                 | Destination                                          |
|-----------------------------------------------------------|------------------------------------------------------|
| `location_country` / `location_region` / `location_locality` / `location_metro` / `location_continent` | Resolved through the chain in [doc 12 §6](12_location.md) → `ref.location.id` written to `integration.person.location_id`. |
| `location_postal_code` / `location_geo` | V20 Option C inline scalars: `integration.person.postal_code` directly; `geo` parsed into `latitude` / `longitude` numeric(9,6) scalars. No separate address table. |
| `location_street_address` / `location_address_line_2` | Not persisted. V16 dropped — PDL bool-placeholders on this subscription tier (person.home grain only). |
| `street_addresses[]` (historical, plural)                 | Not persisted. V16 — PDL bool-placeholder on this tier. |
| `location_names[]`                                        | Each resolves to `ref.location.id` → row in `integration.person_location`. |
| `countries[]`                                             | Each resolves to `ref.country.id` → row in `integration.person_country`. |
| `regions[]`                                               | Each resolves to `ref.state_province.id` → row in `integration.person_state_province`. |

### 6.3 Profiles (social)

| PDL field             | Destination                                              |
|-----------------------|----------------------------------------------------------|
| `linkedin_id` / `linkedin_url` / `linkedin_username` | `integration.person.linkedin_id` / `_url` / `_username` (canonical primary; PDL emits real values for LinkedIn) |
| `facebook_*`, `twitter_*`, `github_*` | Not persisted. V16 dropped — PDL bool-placeholders on this subscription tier. |
| `profiles[]`          | Not persisted. V11 dropped `pdl_person_profiles_parsed`; V16 dropped `integration.person_social_network`. No real source on this tier. |

### 6.4 Experience (`experience[]`)

| PDL field                              | Destination                                                          |
|----------------------------------------|----------------------------------------------------------------------|
| `experience[].company.id`              | Resolve to `integration.company.id` → `integration.experience.company_id` |
| `experience[].company.*` (all sub-fields) | `integration.company.*` (doc 08; one company row per `pdl_id`)    |
| `experience[].title.name`              | `integration.experience.title` (raw text)                            |
| `experience[].title.class`             | Resolve to `ref.job_title_class.id` → `integration.experience.title_class_id` (V25 Option E — 3 independent FKs, not a composite) |
| `experience[].title.role`              | Resolve to `ref.job_title_role.id` → `integration.experience.title_role_id` |
| `experience[].title.sub_role`          | Resolve to `ref.job_title_subrole.id` → `integration.experience.title_sub_role_id` |
| `experience[].title.levels[]`          | Resolve each to `ref.seniority_level.id` → `integration.experience_seniority_level` rows |
| `experience[].title.raw`               | Not persisted (free-text variant; `title` field captures the canonical) |
| `experience[].start_date` / `end_date` | `integration.experience.start_year` / `end_year` (int4 year-only per V25)            |
| `experience[].is_primary`              | `integration.experience.is_primary`                                  |
| `experience[].summary`                 | `integration.experience.summary`                                     |
| `experience[].location_names[]`        | Resolve each to `ref.location.id` → `integration.experience_location` rows |
| `experience[].first_seen` / `last_seen` / `num_sources` | Not persisted (PDL provenance metadata; raw retains). |

**Flat `job_company_*` and `job_title_*` fields** (current job, duplicated on person record): not persisted. Same data is available via `WHERE integration.experience.is_primary = true` joining `integration.company`. Avoids two copies of the current employer.

**`job_history[]`**: not persisted in integration. Stays in raw — it's a different concept (appeared/disappeared positions log, not structured experience) and doesn't fit current use cases.

### 6.5 Education (`education[]`)

| PDL field                                | Destination                                                      |
|------------------------------------------|------------------------------------------------------------------|
| `education[].school.id`                  | Resolve to `integration.school.id` → `integration.person_education.school_id` |
| `education[].school.*` (name, domain, type, website, linkedin/facebook/twitter, location) | `integration.school.*`; school location resolves through doc 12 chain → `integration.school.location_id` |
| `education[].start_date` / `end_date`    | `integration.person_education.start_year` / `end_year` (int4 — V26 switched from timestamptz, mirrors V25 experience pivot; PDL emits year-only precision) |
| `education[].degrees`                    | `integration.person_education.degrees` (jsonb)                   |
| `education[].majors`                     | `integration.person_education.majors` (jsonb)                    |
| `education[].minors`                     | `integration.person_education.minors` (jsonb)                    |
| `education[].gpa`                        | `integration.person_education.gpa`                               |
| `education[].summary`                    | `integration.person_education.summary`                           |
| `education[].raw[]`                      | Not persisted.                                                   |

### 6.6 Multi-valued attribute arrays

| PDL field          | Destination                                                                   |
|--------------------|-------------------------------------------------------------------------------|
| `skills[]`         | Resolve each to `ref.skill.id` → `integration.person_skill` row               |
| `interests[]`      | Resolve each to `ref.interest.id` → `integration.person_interest` row         |
| `languages[]`      | Resolve each to `ref.language.id` → `integration.person_language` row (drops proficiency) |
| `certifications[]` | Not persisted. V10 dropped from staging + V16 dropped `integration.person_certification` (not delivered on this PDL subscription tier). |

### 6.7 Job classification

| PDL field             | Destination                                                                    |
|-----------------------|--------------------------------------------------------------------------------|
| `job_title_role`      | Resolve to `ref.job_title_role.id` → `integration.experience.title_role_id`     |
| `job_title_sub_role`  | Resolve to `ref.job_title_subrole.id` → `integration.experience.title_sub_role_id` |
| `job_title_class`     | Resolve to `ref.job_title_class.id` → `integration.experience.title_class_id`   |
| `job_title_levels[]`  | `ref.seniority_level` (junctioned at experience level via `experience_seniority_level`) |
| `job_onet_*`          | Not persisted (O*NET codes — out of scope; revisit if needed)                  |

---

## 7. Identity & Cross-System IDs — Out of This Schema

Per [requirements/01 §4](../requirements/01_pipeline_requirements.md),
cross-system identifiers do **not** live on `integration.person`. They
belong in the catalog identity ledger:

- `internal_person_id` — stable surrogate that survives rebuilds,
  assigned via identity-signature lookup, exposed as the cross-system
  contract to downstream systems.
- Any external-system IDs (a downstream application's person id, or a
  second data source's id if one is ever added) — additional columns on
  `catalog.person_key_map`, not on the entity.

The integration table is rebuildable from raw; the ledger persists across
runs and is the *only* stateful piece. This split is what makes "tear
down and rebuild" safe — surrogate `integration.person.id` reshuffles on
rebuild, but `internal_person_id` would not, so downstream consumers
would remain valid.

Schema for `catalog.person_key_map` lives in `modeling/dbml/catalog.dbml`;
populating it (identity resolution) is not built. Until it is,
`integration.person.id` is the rebuild-local ROW_NUMBER placeholder
(ADR-0010) and `pdl_id` is the stable key.

---

## 8. Stateless Rebuild Behavior

Every pipeline run rebuilds `raw.pdl_person`, `ref.*`, and `integration.*`
from current source data. Implications:

1. **Surrogate IDs are not stable across rebuilds.** Cached
   `integration.person.id = 42`, `ref.location.id = 99`, etc. are
   invalidated after each run. Downstream consumers must query by
   natural keys (`pdl_id`, `ref.country.name_lc`, etc.).
2. **Search results change after data changes.** A person who moves cities
   between snapshots will appear under a different `ref.location` row on
   the next rebuild. "Show all people in San Francisco" returns
   different sets across rebuilds — expected behavior, not a bug.
3. **Identity continuity is kept separately.** `pdl_id` is stable
   across rebuilds today; the target is `internal_person_id` from
   `catalog.person_key_map` (not yet populated). See §7.
4. **Loader ordering matters within a rebuild.** Resolution chain (per
   doc 12 §6): country → state_province → city → metro → location →
   person/company/school/etc. The dbt DAG enforces this ordering (ref
   models build before the integration models that join them).

---

## 9. Open Questions / Decisions to Confirm

1. **`mobile_phone` PII handling — RESOLVED**. V16 dropped after
   verifying it's a PDL bool-placeholder on this subscription tier. No PII concern; no storage.
2. **`certifications[]` — RESOLVED**. V10 dropped from staging, V16
   dropped `integration.person_certification`. PDL doesn't deliver
   certifications on this subscription tier. Re-add via additive
   migration if a future source emerges.
3. **`languages[].proficiency` (1-5).** Dropped. Add column to
   `person_language` if downstream needs it.
4. **`job_history[]` vs `experience[]`.** Only
   `experience[]` is persisted. `job_history[]` (the "appeared/disappeared positions
   log") stays in raw. Confirm.
5. **O*NET codes** (`job_onet_*` on PDL). Dropped. Add if
   industry/role analysis needs the federal occupational taxonomy.
6. **`work_email` storage.** In the schema (it's not technically
   PII the same way personal email is — work emails are public-ish). PII
   policy may still apply.
7. **Re-resolving experience.company_id across rebuilds.** Since
   surrogate IDs aren't stable (§8), the *integration.experience* row's
   `company_id` is also resolved per rebuild via the company's `pdl_id`.
   The natural-key path (pdl_id) is what carries continuity, not the
   surrogate. Confirm the rebuild ordering: companies built before
   experience joins them.

---

## 10. Future Expansion

**Seeded reference data — not planned** ([ADR-0011](../decisions/0011-loader-discovered-ref-tables.md)). Advisory columns (ISO codes, MSA codes, continent) stay NULL. Loader-discovered from PDL data is the settled approach; external-standard seeding is rejected because both external standards and PDL canonical lists drift on their own schedules and loader-discovered eliminates the drift-detection burden.

**PDL Company Enrichment** (V28, built) — `integration.company` enrichment-only columns are populated; jsonb columns added for NAICS / SIC / tags / alt-names / alt-domains / funding stages / employee-count-by-country (per the jsonb-not-junction scope decision, [doc 08 §1](08_company.md)); `integration.company_affiliation` junction added for hierarchy. See [doc 08 §4.1-§4.2](08_company.md).

**`integration.person_job_history`** if PDL's `job_history[]` becomes a use case.

**Stable `internal_person_id`** assignment in `catalog.person_key_map` — not built; see §7.

---

## 11. Convenience Views

Proposed denormalized read-friendly views (not created yet; they would
ship as hand-authored `R__view_*.sql` migrations) to support common query
patterns without forcing every consumer to join through the snowflake.

```sql
-- Person + current location flattened (address scalars are inline on
-- integration.person per V20 Option C — no separate address table)
CREATE VIEW integration.v_person_denorm AS
SELECT p.id, p.pdl_id, p.full_name, p.headline,
       p.industry_id, ind.name AS industry,
       p.location_id, c.name_lc AS country, sp.name_lc AS state_province,
                       city.name_lc AS city, m.name_lc AS metro,
       p.postal_code, p.latitude, p.longitude
FROM integration.person p
LEFT JOIN ref.industry          ind  ON ind.id  = p.industry_id
LEFT JOIN ref.location          l    ON l.id    = p.location_id
LEFT JOIN ref.country           c    ON c.id    = l.country_id
LEFT JOIN ref.state_province    sp   ON sp.id   = l.state_province_id
LEFT JOIN ref.city              city ON city.id = l.city_id
LEFT JOIN ref.metro             m    ON m.id    = l.metro_id;

-- Experience + company + classification flattened
CREATE VIEW integration.v_experience_denorm AS
SELECT e.id, e.person_id, e.company_id, comp.name AS company_name,
       e.title, cls.name AS title_class, rl.name AS title_role, sr.name AS title_sub_role,
       e.start_year, e.end_year, e.is_primary
FROM integration.experience      e
LEFT JOIN integration.company    comp ON comp.id = e.company_id
LEFT JOIN ref.job_title_class    cls  ON cls.id  = e.title_class_id
LEFT JOIN ref.job_title_role     rl   ON rl.id   = e.title_role_id
LEFT JOIN ref.job_title_subrole  sr   ON sr.id   = e.title_sub_role_id;
```

Create them, and others, as concrete query patterns emerge.
