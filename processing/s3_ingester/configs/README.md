# Source configs

One YAML per source. Loader reads its keys to call the per-file primitive `ingest_file(...)` for every pending `catalog.ingestion_file` row. Finder reads additional keys (S3 layout, regex, sentinel) — both consumers share the same file.

Per-file values (`s3_key`, `target_table`, `partition_value`) come from the `ingestion_file` rows that Finder wrote — **not from this YAML.**

## Schema (Loader-facing keys)

| Key | Required? | Example | Notes |
|---|---|---|---|
| `column_list` | yes | `payload` | Comma-separated columns the COPY targets. |
| `copy_options` | yes | `(FORMAT csv, DELIMITER E'\x01', QUOTE E'\x02')` | Postgres COPY options string. Outer parens are required — substituted verbatim into `COPY ... FROM STDIN WITH <copy_options>`, which requires modern parenthesized syntax. |
| `bucket` | yes | `pdl-ingest-local` | S3 bucket name. |
| `region` | yes | `us-east-1` | AWS region for the S3 bucket. |
| `partition_column` | partitioned mode | `partition_id` | Column the parent table is `PARTITION BY LIST` on. |
| `partition_value_type` | partitioned mode | `smallint`, `text`, `integer` | Used when building the leaf's `FOR VALUES IN (…)` literal and `SET DEFAULT`. |
| `replace_strategy` | optional (default `per_partition`) | `full`, `per_partition` | Controls how previous deliveries' data is handled — see below. |

`partition_column` and `partition_value_type` must both be present (partitioned mode) or both absent (flat-table mode). Validated on load.

### `replace_strategy` — preventing stale data from prior deliveries

Per-partition replacement (the default) only TRUNCATEs leaves the new delivery has files for. This is safe when each partition_value carries **independent semantics that persist across deliveries** (a partition with no new file should keep its previous data). It's **unsafe** when each delivery is a **complete snapshot** — e.g. PDL — because a partition_value present in delivery N but absent in delivery N+1 would leave stale rows under the parent.

| `replace_strategy` | Loader behavior at delivery start | Use for |
|---|---|---|
| `full` | TRUNCATE each parent target_table referenced by the delivery (cascades to all leaves) before the per-file load loop. Empty leaves remain for partition_values absent from this delivery; harmless, but accumulate. | PDL (full snapshots) |
| `per_partition` *(default)* | No parent-level reset. Each leaf is independently TRUNCATE+COPYed by the per-file primitive only when this delivery has a file for it. | Independently-delivered partitions |

Validated against the whitelist `{full, per_partition}`; an invalid value raises a clean error at config-load time.

## What a `file_group` is

A `file_group` is a logical group of S3 files that **share the same target table and load semantics**. Within a group, files share the regex shape (`key_pattern`), destination (`target_table`), and the partition-value extraction rule (`partition_value_from`). Files differ only in their per-file partition value (e.g. PDL's `partition_id` parsed from filename).

| Source | file_groups per delivery | Files per group |
|---|---|---|
| **PDL** | **4** — `pdl_data` (snapshot), `pdl_merged`, `pdl_deleted`, `pdl_opted_out` (deltas) | `pdl_data`: many part files; deltas: a few each |

Why the abstraction: PDL splits one delivery across **4 raw tables** (full snapshot + 3 delta types). Each needs its own regex + target, so modeling them as 4 file_groups is natural. Finder iterates `file_groups`, lists each one's S3 prefix, and applies its key_pattern.

## Finder-facing keys

| Key | Required? | Example | Notes |
|---|---|---|---|
| `sentinel.key_pattern` | yes | `"{delivery_date}/COMPLETED"` | Sentinel S3 key. `{delivery_date}` is substituted from Finder's `--delivery-date`. Finder fails if missing (delivery not ready). |
| `file_groups` | yes | (list) | One entry per logical group of files. See below. |
| `file_groups[].name` | yes | `pdl_data` | Diagnostic name; used in error messages. |
| `file_groups[].s3_list_prefix` | yes | `"{delivery_date}/data/"` | Passed to boto3 `list_objects_v2` as `Prefix`. |
| `file_groups[].key_pattern` | yes | `"^{delivery_date}/data/part-(?P<partition_id>\\d{5})\\.csv\\.gz$"` | Regex matched against the **full** S3 key. The named group given by `partition_value_from` is extracted as the partition value. `{delivery_date}` is substituted (regex-escaped). |
| `file_groups[].target_table` | yes | `raw.pdl_person` | Schema-qualified destination. Finder writes this into each `ingestion_file` row. |
| `file_groups[].partition_value_from` | yes | `partition_id` | Named regex group whose match becomes `ingestion_file.partition_value`. |
| `file_groups[].optional` | no (default `false`) | `true` | If `false`, Finder fails when the group matches no files. If `true`, missing/empty group is skipped silently (used for delta folders that may be absent). |

Post-load SQL functions (e.g. `project_pdl_deltas` for PDL) are out of scope for this YAML — `run.py` invokes them after the Loader (via `pdl_projection_runner.py`), not Finder/Loader themselves.

Finder does not write to S3. The Loader gunzips `.gz` objects itself, so no Content-Encoding metadata fix-up is needed.

## Files

- [`pdl_full.yaml`](pdl_full.yaml) — PDL monthly snapshot + delta-folder loads (real delivery bucket; placeholder name).
- [`pdl_full_local.yaml`](pdl_full_local.yaml) — identical, but pointed at the local S3 bucket `pdl-ingest-local`.
