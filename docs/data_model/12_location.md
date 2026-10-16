# Location & Address Schema — Canonical Place Hierarchy

**Status:** Implemented (ref place models in `processing/dbt/models/ref/`; inline address scalars since V20 / V24). The §7 views are proposals, not created.
**Person-tier sources:** `raw.pdl_person.*` (PDL Person bulk delivery) —
- `person.location_*` (person home)
- `person.experience[].company.location.*` (company HQ from person.experience)
- `person.education[].school.location.*` (school)
- `person.location_names[]`, `countries[]`, `regions[]` (derived sets — junctions on `integration.person_*`)

**Enrichment source:** PDL Company Enrichment API (`location.*` on the company record) — lands via the LEFT JOIN + COALESCE merge in `integration/company.sql`, see [doc 08 §5.2](08_company.md)

**Companion docs:**
- [doc 08 — Company schema](08_company.md) — `integration.company.location_id` + inline address scalars
- [doc 10 — Canonical reference tables](10_reference_tables.md) — `ref.*` catalog + loader-discovered convention (ADR-0011)
- [doc 13 — Person schema](13_person.md) — `integration.person.location_id` + inline address scalars, plus `experience` and `school` locations
- [requirements/01 — Pipeline requirements](../requirements/01_pipeline_requirements.md) §2 — stateless content rebuild + stateful identity ledger

---

## 1. Purpose

A canonical, normalized representation of place data shared across every
entity that has a location — company, person, school today, and any
additional located entity (e.g. office) later.

Two concerns kept separate:

- **Place** — canonical hierarchical dimensions (country, state/province,
  city, metro, continent). Bounded cardinality. Reused across millions
  of entity rows.
- **Address** — entity-specific street-level data (street address,
  postal code, geo lat/lng). Unbounded cardinality. One row per entity
  with street data.

This split lets us answer "all employees in the San Francisco metro" via
a clean equi-join on `ref.metro`, instead of string-matching denormalized
text across every entity table. It also lets us curate place data
(lat/lng centroids, population, MSA codes) once and inherit it everywhere.

---

## 2. Design Principles

1. **Normalize the place hierarchy.** Each level (country / state_province
   / city / metro / continent) is its own ref table with a surrogate PK.
   `ref.location` is a composite of FKs into the four — one row per
   distinct (country, state_province, city, metro) tuple PDL emits. No
   denormalized place strings on `ref.location` (use views to flatten —
   see §7).

2. **Single grain per `ref.location` row.** A location row is the *most
   specific* level PDL emits for that physical place. NULLs go upward —
   a row with only `country_id` populated represents "country grain,
   nothing finer."

3. **`ref` for canonical dimensions — all loader-discovered.**
   Country, state_province, city, metro, continent are all loader-populated
   from PDL data. Per [ADR-0011](../decisions/0011-loader-discovered-ref-tables.md),
   we don't seed ref tables from external standards. Advisory columns for
   ISO codes / MSA codes / etc. exist in DDL but stay NULL unless a specific
   consumer use case emerges.

4. **Address data is inline scalars on the entity tables** (V20/V24
   Option C). PDL emits each entity's address as a single object per
   source row; empirical verification confirmed 1:1 cardinality between
   entity and address. A separate address table is pure indirection —
   so the address fields live as scalar columns directly on
   `integration.person` and `integration.company`. No separate
   `integration.address` table exists.

5. **One FK + scalars per entity** (consistent across company, person, school):
   - `location_id` FK → `ref.location.id` — always populated when any place data exists (the canonical place hierarchy)
   - `latitude`, `longitude`, `postal_code`, `street_address`,
     `address_line_2` — inline scalar columns where the entity has
     street-level data (V20 for person — only lat/long/postal; V24 for
     company — full address scalars). NULL when PDL emits no
     street-level data. `integration.school` has only `location_id`
     (PDL emits coarse-grain only for schools).

6. **No seeded ref layer — settled per ADR-0011.** All `ref.*` place
   tables are loader-populated from PDL. ISO / MSA / continent seed
   migrations are NOT planned; advisory columns stay NULL unless a
   specific consumer use case emerges to fill them.

7. **Stateless content rebuild applies to `ref.*` too.** `ref.*` and
   `integration.*` tables can be torn down and rebuilt from `raw.*` on
   every pipeline run. The `catalog.*` identity ledger is the only
   stateful component. **Surrogate IDs (`ref.location.id`,
   `ref.country.id`, etc.) are not stable across rebuilds** — downstream
   consumers must query by natural keys (`country.name_lc = 'united
   states'`, `pdl_company_id`, etc.), never by stored surrogate IDs. A
   cached `location_id = 42` is invalid after a rebuild.

8. **No address history.** PDL `street_addresses[]` (historical
   addresses) stays in raw, never persisted. Each rebuild reflects only
   the *current* `location_*` and `street_address` PDL emits. As a
   person moves, their `integration.person.location_id` and inline
   scalars point at a new place on the next rebuild — search "people in
   San Francisco" returns different result sets across rebuilds. This
   is expected behavior under the stateless model.

---

## 3. Entity-Relationship Overview

```
        ref.continent
              │ id ◄──────────────┐
              │                   │
        ref.country               │  continent_id FK
              │ id ◄────┐ ────────┘
              │         │
        ref.state_     ─┤  country_id FK
        province        │
              │ id ◄────┤
              │         │
        ref.city  ──────┤  country_id FK, state_province_id FK NULL
              │ id ◄────┤
              │         │
        ref.metro ──────┤  country_id FK
              │ id ◄────┘
              ▼
      ┌──────────────────────────────────────────────────────────────┐
      │                       ref.location                           │
      │  id PK · country_id FK · state_province_id FK NULL           │
      │       · city_id FK NULL · metro_id FK NULL                   │
      │  UNIQUE on the four FK columns (COALESCE NULL → 0)           │
      └──────────────────────────┬───────────────────────────────────┘
                                 │
                                 │ id (referenced by entity location_id FK)
                                 ▼

  Entity tables carry inline address scalars (V20/V24 Option C):

    integration.person   ── location_id FK + latitude / longitude /
                            postal_code scalars
                            (V20 — no street-level PDL data on person tier)

    integration.company  ── location_id FK + latitude / longitude /
                            postal_code / street_address /
                            address_line_2 scalars (V24 — full address)

    integration.school   ── location_id FK only
                            (PDL emits coarse-grain only for schools)

  No separate integration.address table.
```

---

## 4. Table-by-Table Specification

Notation: `PK` primary key, `FK` foreign key, `*` not-null. Types are
PostgreSQL flavor. All tables carry `timestamp_created timestamptz
DEFAULT now()` and `timestamp_modified timestamptz DEFAULT now()`,
omitted below for brevity. Under the rebuild-each-run model these
timestamps reflect the current rebuild, not historical creation.
There are no `display_name` columns on the place tables; a
`name_display` companion is proposed in
[design/21 §4](../design/21_cleansing_layer_design.md#4-casing-convention).

### 4.1 `ref.continent`

| Column         | Type     | Notes                                              |
|----------------|----------|----------------------------------------------------|
| `id` *         | `bigint` | PK, dbt-computed `ROW_NUMBER()` (ADR-0008)         |
| `name_lc` *    | `text`   | UNIQUE. PDL canonical (`"north america"`, …).      |

Loader-populated from PDL `location.continent` strings; tiny table
(~7 rows). No seed (ADR-0011).

### 4.2 `ref.country`

| Column          | Type     | Notes                                              |
|-----------------|----------|----------------------------------------------------|
| `id` *          | `bigint` | PK, dbt-computed (ADR-0008)                        |
| `name_lc` *     | `text`   | UNIQUE. PDL canonical (lowercase English, `"united states"`). Join key. |
| `continent_id`  | `bigint` | FK → `ref.continent.id`. Resolved by the `ref.country` model from the continent PDL emits alongside the country (NULL when none is emitted). |
| `iso_alpha_2`   | `text`   | Advisory; NULL. Never populated (per ADR-0011 no seeded ref layer). |
| `iso_alpha_3`   | `text`   | Advisory; NULL. Same reason. |

**Loader:** `SELECT DISTINCT` on `name_lc` from PDL strings. ISO columns
NULL — per [ADR-0011](../decisions/0011-loader-discovered-ref-tables.md) we don't seed ref tables from external standards. Advisory columns kept in DDL for future flexibility; won't be populated unless a specific consumer use case emerges.

### 4.3 `ref.state_province`

Named `state_province` (not `state`) to cover both US states, Canadian
provinces, and other top-level subdivisions ISO 3166-2 enumerates.

| Column                   | Type     | Notes                                              |
|--------------------------|----------|----------------------------------------------------|
| `id` *                   | `bigint` | PK, dbt-computed (ADR-0008)                        |
| `country_id` *           | `bigint` | FK → `ref.country.id`                              |
| `name_lc` *              | `text`   | PDL canonical region string, lowercased (`"california"`). |
| `iso_subdivision_code`   | `text`   | Advisory ISO 3166-2 (`"US-CA"`); NULL — not seeded (ADR-0011) |

**UNIQUE** on `(country_id, name_lc)`.

**Loader:** resolve `country_id` first; `DISTINCT` on `(country_id, name_lc)`.

### 4.4 `ref.city`

| Column                | Type     | Notes                                              |
|-----------------------|----------|----------------------------------------------------|
| `id` *                | `bigint` | PK, dbt-computed (ADR-0008)                        |
| `country_id` *        | `bigint` | FK → `ref.country.id`                              |
| `state_province_id`   | `bigint` | FK → `ref.state_province.id`. NULL when PDL emits city without region. |
| `name_lc` *           | `text`   | PDL canonical city string, lowercased (`"san francisco"`). |

**UNIQUE** on `(country_id, COALESCE(state_province_id, 0), name_lc)`.

**Loader:** resolve `country_id` and `state_province_id` first; `DISTINCT` on the key.

Loader-populated only (no seed source at this grain). At PDL scale expect
hundreds of thousands of distinct cities.

### 4.5 `ref.metro`

| Column         | Type     | Notes                                              |
|----------------|----------|----------------------------------------------------|
| `id` *         | `bigint` | PK, dbt-computed (ADR-0008)                        |
| `country_id` * | `bigint` | FK → `ref.country.id`                              |
| `name_lc` *    | `text`   | PDL canonical metro string (`"san francisco bay area"`). |
| `msa_code`     | `text`   | Advisory US Census MSA code; NULL — not seeded (ADR-0011) |

**UNIQUE** on `(country_id, name_lc)`.

PDL's metro canon doesn't always match US Census MSA naming (PDL:
`"san francisco bay area"`; Census:
`"San Francisco-Oakland-Berkeley, CA"`). Accept PDL's canon as the join
key; Census MSA codes stay NULL (not seeded per ADR-0011).

### 4.6 `ref.location`

| Column                | Type     | Notes                                              |
|-----------------------|----------|----------------------------------------------------|
| `id` *                | `bigint` | PK, dbt-computed (ADR-0008)                        |
| `country_id` *        | `bigint` | FK → `ref.country.id`                              |
| `state_province_id`   | `bigint` | FK → `ref.state_province.id` (NULL = no region grain) |
| `city_id`             | `bigint` | FK → `ref.city.id` (NULL = no locality grain)      |
| `metro_id`            | `bigint` | FK → `ref.metro.id` (NULL = no metro grain)        |

**UNIQUE** on `(country_id, COALESCE(state_province_id, 0), COALESCE(city_id, 0), COALESCE(metro_id, 0))`.

The "grain row" — one per distinct (country, state_province, city,
metro) tuple PDL emits. NULLs upward in the hierarchy. Country is always
populated; finer grains are optional.

**Why COALESCE(…, 0) in the UNIQUE.** Postgres treats `NULL` as distinct
in UNIQUE constraints by default. Without coalescing, two rows with the
same country and NULL state_province would both be inserted. The 0
sentinel works because the dbt-computed `ROW_NUMBER()` ids start at 1.

### 4.7 No separate `integration.address` table

V6 baseline created `integration.address` as a shared per-entity
street-level table. The V20→V24 design evolution dropped it entirely
once empirical 1:1 cardinality with the parent entities was verified:

- V20: `integration.person` inlined `latitude / longitude / postal_code`
  scalars (Option C); dropped `person.address_id`. PDL person tier has
  no street-level data on the current subscription.
- V21: renamed `integration.address` → `integration.company_hq_address`
  (only used by company at that point).
- V24: dropped the renamed table; inlined scalars on `integration.company`
  too (`latitude`, `longitude`, `postal_code`, `street_address`,
  `address_line_2`). Every company in a profiled full delivery had
  exactly one distinct address; PDL emits the canonical company sub-
  object per occurrence (per [doc 08](08_company.md) §6). Separate
  table was pure indirection.

**Where address data lives now:**

| Entity table | Address columns (inline scalars) | Has FK to ref.location? |
|---|---|---|
| `integration.person` | `latitude`, `longitude`, `postal_code` (V20) | yes, `location_id` |
| `integration.company` | `latitude`, `longitude`, `postal_code`, `street_address`, `address_line_2` (V24) | yes, `location_id` |
| `integration.school` | (none — PDL coarse-grain only) | yes, `location_id` |

The `ref.location` hierarchy (§4.6) remains the canonical place reference.
The address scalars sit *alongside* `location_id` on the entity, not
*chained through* a separate address row.

**No address-content UNIQUE constraint anywhere** — formatting variance
across sources makes cross-entity dedup not worth fighting. PDL's
contract that company sub-objects are canonical-identical per
occurrence is the empirical basis for "one address per entity" — no
constraint enforcement needed.

**No `is_current` or `pdl_last_updated` columns** — under the stateless
rebuild model, every row is current by construction. Historical address
data lives in raw and is replaced on every rebuild (see §8).

---

## 5. PDL → Schema Mapping

PDL emits `location.*` as a sub-object on multiple parent records:

- `person.location_*` (top-level on the person record)
- `person.experience[].company.location.*`
- `person.education[].school.location.*` (coarse-grain only — continent / country / region / locality; no street, no metro)
- `company.location.*` from PDL Company Enrichment

Same mapping applies — the entity differs but the location sub-object
is identical in shape.

| PDL field                                  | Destination                                                       |
|--------------------------------------------|-------------------------------------------------------------------|
| `location.country`                         | `ref.country` (distinct `name_lc`)                                |
| `location.continent`                       | `ref.continent` (distinct `name_lc`); also resolved onto `ref.country.continent_id` |
| `location.region`                          | `ref.state_province` (distinct `(country_id, name_lc)`)           |
| `location.locality`                        | `ref.city` (distinct `(country_id, state_province_id, name_lc)`)  |
| `location.metro`                           | `ref.metro` (distinct `(country_id, name_lc)`)                    |
| `(country, state_province, city, metro)` tuple | `ref.location` row (distinct composite-FK tuple) → entity's `location_id` column |
| `location.street_address`                  | `integration.company.street_address` (V24 inline scalar; not persisted for person — PDL person tier has no street data) |
| `location.address_line_2`                  | `integration.company.address_line_2`                              |
| `location.postal_code`                     | `integration.person.postal_code` (V20) / `integration.company.postal_code` (V24) — inline scalars |
| `location.geo`                             | parsed → `latitude` / `longitude` inline scalars on the entity (V20 for person, V24 for company) |
| `location.name`                            | Not persisted — denormalized human string, derivable from view §7 |
| `street_addresses[]` (historical, PDL person) | Not persisted. V16 — PDL bool-placeholder on person tier; only current address would have been kept anyway. |
| `location_last_updated`                    | `integration.person.location_last_updated` (V17 added as a freshness signal). |

Loader writes the resolved `location_id` (always) and the address
scalars (when PDL emits street-level data) directly onto the parent
entity row. No separate address-table INSERT.

**Note on school location.** PDL emits school location with **coarse
grain only** — continent / country / region / locality. No street, no
metro, no postal. `integration.school` carries only `location_id` (no
inline scalars).

---

## 6. Loader Resolution Chain

Resolution is set-based dbt, not per-entity upserts. Every run rebuilds
the place tables from `staging.pdl_person_addresses_unique`, in DAG
order:

```
1. ref.continent       = DISTINCT LOWER(continent)
2. ref.country         = DISTINCT LOWER(country); continent_id via LEFT JOIN to #1
3. ref.state_province  = DISTINCT (country_id, LOWER(region))
4. ref.city            = DISTINCT (country_id, state_province_id, LOWER(locality))
                         (state_province_id NULL when PDL emitted no region)
5. ref.metro           = DISTINCT (country_id, LOWER(metro))
6. ref.location        = DISTINCT (country_id, state_province_id, city_id, metro_id)
                         — country INNER JOIN, finer levels LEFT JOIN

   Each model assigns id = ROW_NUMBER() OVER (ORDER BY <natural key>) (ADR-0008).

7. integration.person / integration.company / integration.school:
     location_id     = JOIN back to ref.location on the same tuple
     latitude        = parsed from PDL location.geo (person + company)
     longitude       = parsed from PDL location.geo
     postal_code     = PDL location.postal_code (person + company)
     street_address  = PDL location.street_address  (company only)
     address_line_2  = PDL location.address_line_2  (company only)
```

Joins use `LOWER()` on every key and `COALESCE(<fk>, 0)` on nullable
parent FKs, mirroring the V5 expression-based UNIQUE indexes so the
planner can use them (see the header comment in
`processing/dbt/models/ref/location.sql`).

## 7. Denormalized Convenience Views

`ref.*` and the entity tables (with their inline address scalars) are
queried often through joins. These views would flatten the joins for
read-friendly access. **They are proposals — no migration creates them
yet**; they would ship as hand-authored `R__view_*.sql` files:

```sql
CREATE VIEW ref.v_location_denorm AS
SELECT l.id                  AS location_id,
       c.name_lc             AS country,
       sp.name_lc            AS state_province,
       city.name_lc          AS city,
       m.name_lc             AS metro,
       cont.name_lc          AS continent
FROM   ref.location           l
JOIN   ref.country            c    ON c.id    = l.country_id
LEFT   JOIN ref.state_province sp  ON sp.id   = l.state_province_id
LEFT   JOIN ref.city           city ON city.id = l.city_id
LEFT   JOIN ref.metro          m   ON m.id    = l.metro_id
LEFT   JOIN ref.continent      cont ON cont.id = c.continent_id;

-- Person flattened — address scalars are inline (V20 Option C)
CREATE VIEW integration.v_person_address_denorm AS
SELECT p.id            AS person_id,
       p.pdl_id,
       p.latitude,
       p.longitude,
       p.postal_code,
       v.country, v.state_province, v.city, v.metro, v.continent
FROM   integration.person     p
LEFT JOIN ref.v_location_denorm v ON v.location_id = p.location_id;

-- Company flattened — full inline address (V24 Option C)
CREATE VIEW integration.v_company_address_denorm AS
SELECT c.id            AS company_id,
       c.pdl_company_id,
       c.street_address, c.address_line_2,
       c.postal_code, c.latitude, c.longitude,
       v.country, v.state_province, v.city, v.metro, v.continent
FROM   integration.company    c
LEFT JOIN ref.v_location_denorm v ON v.location_id = c.location_id;
```

Create them when a query reader wants flat strings rather than walking
the snowflake; add more as concrete query patterns emerge.

---

## 8. Stateless Rebuild Behavior

Every pipeline run rebuilds `ref.*` and `integration.*` from current
`raw.*` (no seed migrations per ADR-0011). Implications:

1. **Surrogate IDs are not stable.** `ref.location.id`, `ref.city.id`,
   etc. shuffle on every rebuild. Downstream consumers must query by
   natural keys (`country.name_lc`, `pdl_id`, etc.), never by stored
   `location_id`.
2. **Location reflects latest snapshot.** A person who moves cities
   between snapshots gets a new `ref.location` row reference. "Show all
   people in San Francisco" returns different result sets after a
   rebuild — expected, not a bug.
3. **No address history.** Historical `street_addresses[]` from PDL
   stays in raw. Entity address scalars (on `integration.person` /
   `integration.company`) carry the current `location_*` only;
   replaced on every rebuild.
4. **Identity continuity** for downstream consumers comes from natural
   keys (`pdl_id`, `pdl_company_id`); a stable `internal_person_id` in
   `catalog.person_key_map` is designed but not populated — see
   [doc 13 §7](13_person.md).

---

## 9. Open Questions / Decisions to Confirm

1. **Ref seeding rejected — settled per [ADR-0011](../decisions/0011-loader-discovered-ref-tables.md).** All `ref.*` place tables are loader-populated from PDL. Advisory ISO / continent columns stay in DDL but are not filled from any external source. External standards drift on their own schedule; loader-discovered eliminates the drift-detection burden by construction.
2. **Country key shape.** Keep PDL string (`name_lc`) as the FK join key, ISO codes advisory (unfilled per #1).
3. **State name normalization rules.** Loader applies `lower(trim(…))` before insert. Two PDL deliveries emitting `"California"` and `"calif"` for the same state would still create two rows. Periodic audit query identifies outliers; manual merge later if it becomes a real problem.
4. **Metro identity.** PDL canon accepted. Census MSA codes not seeded (per #1).
5. **Address dedup across entities — RESOLVED via V20/V24 inline scalars.** There's no separate address table to dedup; address scalars live directly on each entity. Two entities at the same physical address carry identical scalar values; no cross-row UNIQUE constraint relevant. If exact-match address queries ever become a use case, add an expression index on the entity columns rather than reintroducing a separate table.

---

## 10. Future extensions (not planned)

The following were considered and are NOT planned per current decisions:

- **Seeded advisory columns** (ISO 3166 / ISO 3166-2 / Census MSA / continent taxonomy from pycountry) — rejected per ADR-0011. If a specific consumer use case emerges requiring these, revisit at that point.
- **Address normalization** (geocoding service integration for lat/lng when PDL omits geo, USPS standardization) — separate scope; not planned.
- **Cross-entity address dedup** — not relevant under the inline-scalar shape. If exact-match address queries become a use case, add an expression index on entity columns (`(integration.company.postal_code, street_address)`, etc.) rather than reintroducing a shared address table.
