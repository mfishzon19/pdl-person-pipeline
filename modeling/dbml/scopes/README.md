# Scope manifests for DBML diagram views

This directory contains hand-authored manifest files that define **scopes** — named subsets of tables — for rendering separate, review-sized ERD diagrams from the canonical per-schema DBML sources.

## Why scopes exist

The integration + ref schemas are 30+ tables. Rendered as one diagram (paste of `combine.sh` default output into dbdiagram.io), it's unreadable — too many boxes, too many crossing arrows, auto-layout can't find a sane arrangement.

Scopes carve the schema into review-sized chunks (6–14 tables each), each focused on a specific design concern:

| Scope | Tables | What it shows |
|---|---|---|
| [core](core.txt) | 6 | The 5 central entities plus `ref.location` as a leaf, with their cross-entity FKs (no junctions, no other ref tables) |
| [places](places.txt) | 6 | Geo place hierarchy in isolation (`continent → country → … → location`) |
| [person-attrs](person-attrs.txt) | 7 | Person + multi-valued attribute junctions (ref tables stripped) |
| [exp-attrs](exp-attrs.txt) | 10 | Experience + role attributes + job-title taxonomy |
| [industry](industry.txt) | 6 | Industry attachment surface — everywhere PDL lands an industry FK. Used to design "restrict to industry X" filters. |

## Two-layer architecture

- **Layer 1 (canonical, hand-authored):** per-schema DBMLs (`../ref.dbml`, `../integration.dbml`, `../catalog.dbml`, `../staging.dbml`, `../raw.dbml`, `../pdl_api.dbml`). Source of truth. Scopes read `ref.dbml` + `integration.dbml` by default; `--all` adds `catalog`, `staging` and `raw` (pass files explicitly to include `pdl_api.dbml`).
- **Layer 2 (derived, generated):** scope views produced on demand by `../combine.sh --scope <name>`. Self-contained, single-Project DBML output suitable for dbdiagram.io or `dbml-renderer`.

Scope manifest files (`<name>.txt`) are **review surfaces in their own right** — versioned, comment-supporting, plain-text — separate from the DBML output they generate.

## Manifest format

```
# Comments (lines starting with #) are ignored
# Blank lines are ignored

schema.table_name      # one table per line, schema-qualified
schema.another_table
```

Recommend grouping tables under comment headers (central entity, junctions, ref tables, etc.) — see existing manifests for style.

## Extraction modes

### Default (strict)
Refs to unlisted tables are **stripped** from the output. Junction columns like `country_id` keep their data type but lose their `[ref: > ref.country.id]` annotation — dbdiagram renders them as bare bigint columns with no arrow.

Use when you want the diagram to focus on what's IN the scope. Cleaner, fewer arrows.

```bash
../combine.sh --scope person-attrs | pbcopy
```

### --stubs
Refs to unlisted tables are **kept**; minimal stub Tables are appended at the bottom of the output:
```
Table ref.country {
  id  bigint  [pk]
}
```
dbdiagram resolves the FK and renders an arrow to the stub. The stub box is visually compact (one PK column), so it doesn't dominate the layout.

Use when you want to show "this scope CONNECTS to these things" without pulling all of their columns.

```bash
../combine.sh --scope person-attrs --stubs | pbcopy
```

Same scope file, two viewing modes. Pick per render.

## Adding a new scope

1. Create `scopes/<name>.txt` following the manifest format.
2. Run `../combine.sh --scope <name> | pbcopy` and paste into dbdiagram.io to verify the layout is readable.
3. If too dense, simplify (drop ref tables or non-central tables) and re-test.
4. Optionally add a row to the table at the top of this README.

## Worked examples

```bash
cd modeling/dbml

# Render a scope to clipboard for dbdiagram.io
./combine.sh --scope core | pbcopy

# Save a scope to disk
./combine.sh --scope places > /tmp/places.dbml

# Stubs mode — see FK targets as compact stub tables
./combine.sh --scope exp-attrs --stubs | pbcopy

# Scripted ERD generation (requires `npm i -g @softwaretechnik/dbml-renderer`)
./combine.sh --scope core | dbml-renderer -i /dev/stdin -o /tmp/core.svg

# List all available scopes
./combine.sh --help
```

## Design notes

- **Why not in-DBML annotations?** DBML has no native concept of "view" or "diagram subset." The scope layer is a tooling concern, not a schema concern.
- **Why text manifests instead of YAML/JSON?** Reviewability + diff-readability. A scope is a list of names, not a structured config.
- **Why strip refs by default instead of stubs?** Most reviews want a focused diagram, not "everything this connects to." Stubs are opt-in for the rare case.
