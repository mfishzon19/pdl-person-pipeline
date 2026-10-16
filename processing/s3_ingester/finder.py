"""Per-delivery file Finder (`finder.py`).

Discovers files in S3 for a given (source, delivery_date) per the
`file_groups` declared in `configs/<source>.yaml`, then writes the catalog
rows the Loader needs:

  catalog.pipeline_run    (parent row for ingestion_run's FK — see below)
  catalog.ingestion_run   (one row per source-delivery)
  catalog.ingestion_file  (one row per discovered file, status='pending')
  catalog.pdl_delivery    (PDL-source only — basic insert, see note below)

Returns the new `ingestion_run_id` (the CLI prints it on stdout); the
Loader's --ingestion-run-id flag consumes that value.

What `file_groups` are
----------------------

A "file_group" is a logical group of S3 files that **share the same target
table and load semantics**. PDL has 4 file_groups within one delivery:

  pdl_data       → raw.pdl_person            (many part files, the full snapshot)
  pdl_merged     → raw.pdl_merged_records    (a few delta files; optional)
  pdl_deleted    → raw.pdl_deleted_records   (a few delta files; optional)
  pdl_opted_out  → raw.pdl_opted_out_records (a few delta files; optional)

Within a group, files share regex shape, target_table, and the partition-value
extraction rule. Files differ in their per-file partition value (PDL:
`partition_id` parsed from filename).

pipeline_run row
----------------

catalog.ingestion_run has a FK to catalog.pipeline_run, so Finder INSERTs one
pipeline_run row per invocation (DB assigns the UUID via DEFAULT
gen_random_uuid()). `--pipeline-version` (default 'local') is recorded on the row; pin it
to a git SHA / release tag for traceable runs.

Defensive contracts
-------------------

  - Sentinel must exist; missing sentinel → RuntimeError (delivery not ready).
  - Required file_groups (optional=false) must match ≥1 file → RuntimeError if empty.
  - Optional file_groups silently skip if empty.
  - All catalog INSERTs run in one transaction — partial state never persists.
  - Finder does NOT write to S3. Files are read as delivered; the Loader
    gunzips `.gz` keys itself.

PDL-specific catalog write
--------------------------

For PDL sources (any source named `pdl_*`), Finder also writes one
catalog.pdl_delivery row with status='received'. The pdl_dataset_id (e.g.
'34.0') is parsed from delta_data folder names (`MONTHLY_V_NN.N/`); first
deliveries with no delta_data fall back to 'unknown'. file_counts is a
jsonb of per-file_group counts. The terminal transition ('success' /
'failed' + row_counts and per-delta counts) is written by run.py after the
Loader and projection finish.

Local CLI
---------

    DATABASE_URL='postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl' \\
    AWS_ENDPOINT_URL=http://localhost:9000 \\
    AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=local \\
    python -m processing.s3_ingester.finder \\
        --source pdl_full_local \\
        --delivery-date 2026_05_22
    # stdout: <ingestion_run_id>
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
from pathlib import Path
from typing import Any

import boto3
import yaml
from botocore.exceptions import ClientError

from processing.common.db import connect
from processing.common.logging_setup import configure_logging

logger = logging.getLogger(__name__)

# Configs share a directory with delivery_loader.
_CONFIGS_DIR = Path(__file__).parent / "configs"

# Top-level YAML keys required for Finder. (Loader keys — column_list,
# copy_options, partition_column, partition_value_type — are not Finder's
# concern and aren't validated here.)
_REQUIRED_FINDER_KEYS = frozenset({"sentinel", "file_groups", "bucket", "region"})

# Required keys per file_group.
_REQUIRED_FILE_GROUP_KEYS = frozenset({
    "name", "s3_list_prefix", "key_pattern",
    "target_table", "partition_value_from",
})

# Strict yyyy_mm_dd format for --delivery-date (PDL convention).
_DELIVERY_DATE_RE = re.compile(r"^\d{4}_\d{2}_\d{2}$")

# Pull PDL dataset id (e.g. '34.0') out of any 'MONTHLY_V_NN.N' substring.
_PDL_DATASET_RE = re.compile(r"MONTHLY_V_(\d+\.\d+)")

# Default pipeline_version when --pipeline-version isn't supplied.
_DEFAULT_PIPELINE_VERSION = "local"


# -----------------------------------------------------------------------------
# Public entry point
# -----------------------------------------------------------------------------

def discover_delivery(
    *,
    source: str,
    delivery_date: str,
    db_dsn: str,
    pipeline_version: str = _DEFAULT_PIPELINE_VERSION,
    s3_client: Any = None,
) -> str:
    """Discover files for one delivery and write catalog rows.

    Args:
      source:           Source name (resolves to configs/<source>.yaml).
      delivery_date:    yyyy_mm_dd literal — substituted into S3 key patterns.
      db_dsn:           psycopg2 connection string for the catalog schema.
      pipeline_version: Recorded on pipeline_run.pipeline_version (e.g. git
                        SHA / release tag). Default 'local'.
      s3_client:        Optional boto3 S3 client (mostly for tests).

    Returns:
      The new ingestion_run_id (uuid as str). Caller (run.py or the
      delivery_loader CLI) uses this to drive the Loader.

    Raises:
      FileNotFoundError, ValueError — config issues.
      RuntimeError                  — sentinel missing, required file_group
                                      empty, or no files discovered overall.
      ClientError                   — AWS errors propagate from boto3.
      psycopg2.Error subclasses     — DB errors propagate.
    """
    if not _DELIVERY_DATE_RE.fullmatch(delivery_date):
        raise ValueError(
            f"delivery_date must be 'yyyy_mm_dd', got {delivery_date!r}"
        )

    config = _load_finder_config(source)
    s3 = s3_client or boto3.client("s3", region_name=config["region"])
    bucket = config["bucket"]

    # 1. Sentinel check.
    # A null key_pattern means the source has no COMPLETED-style marker.
    # Skip the readiness check entirely in that case.
    # Use str.replace, not str.format — key_pattern strings can contain regex
    # quantifiers like \d{5}, and .format() would misread {5} as a positional
    # argument index.
    sentinel_pattern = config["sentinel"]["key_pattern"]
    if sentinel_pattern is not None:
        sentinel_key = sentinel_pattern.replace("{delivery_date}", delivery_date)
        if not _s3_object_exists(s3, bucket, sentinel_key):
            raise RuntimeError(
                f"sentinel s3://{bucket}/{sentinel_key} not found — delivery not ready"
            )

    # 2. Discover files per file_group.
    files_to_load = _discover_files(s3, bucket, config["file_groups"], delivery_date)

    if not files_to_load:
        # Should be unreachable given that the required group raises on empty,
        # but guard anyway.
        raise RuntimeError(
            f"no files discovered for {source} delivery {delivery_date}"
        )

    # 3. Write catalog rows in one transaction.
    return _write_catalog_rows(
        db_dsn=db_dsn,
        source=source,
        delivery_date=delivery_date,
        files_to_load=files_to_load,
        file_groups=config["file_groups"],
        pipeline_version=pipeline_version,
    )


# -----------------------------------------------------------------------------
# YAML config loading + validation
# -----------------------------------------------------------------------------

def _load_finder_config(source: str) -> dict[str, Any]:
    path = _CONFIGS_DIR / f"{source}.yaml"
    if not path.exists():
        raise FileNotFoundError(f"source config not found: {path}")
    with path.open() as f:
        config = yaml.safe_load(f)

    if not isinstance(config, dict):
        raise ValueError(
            f"{path}: expected a YAML mapping, got {type(config).__name__}"
        )

    missing = _REQUIRED_FINDER_KEYS - config.keys()
    if missing:
        raise ValueError(f"{path}: missing required Finder keys: {sorted(missing)}")

    if not isinstance(config["sentinel"], dict) or "key_pattern" not in config["sentinel"]:
        raise ValueError(f"{path}: sentinel must be a mapping with 'key_pattern'")

    if not isinstance(config["file_groups"], list) or not config["file_groups"]:
        raise ValueError(f"{path}: file_groups must be a non-empty list")

    for fg in config["file_groups"]:
        if not isinstance(fg, dict):
            raise ValueError(f"{path}: each file_group must be a mapping")
        missing_fg = _REQUIRED_FILE_GROUP_KEYS - fg.keys()
        if missing_fg:
            raise ValueError(
                f"{path}: file_group {fg.get('name', '???')!r} "
                f"missing keys: {sorted(missing_fg)}"
            )
    return config


# -----------------------------------------------------------------------------
# S3 discovery
# -----------------------------------------------------------------------------

def _s3_object_exists(s3, bucket: str, key: str) -> bool:
    """True if key exists in bucket."""
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
            return False
        raise


def _discover_files(
    s3,
    bucket: str,
    file_groups: list[dict[str, Any]],
    delivery_date: str,
) -> list[dict[str, Any]]:
    """List + regex-match files per file_group. Returns flat list of work items."""
    all_files: list[dict[str, Any]] = []

    for fg in file_groups:
        # Use str.replace, not str.format — key_pattern is a regex with
        # quantifiers like \d{5}, and .format() would misread {5} as a
        # positional argument index.
        prefix = fg["s3_list_prefix"].replace("{delivery_date}", delivery_date)
        pattern = re.compile(
            fg["key_pattern"].replace("{delivery_date}", re.escape(delivery_date))
        )
        partition_value_group = fg["partition_value_from"]

        matched: list[dict[str, Any]] = []
        paginator = s3.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                m = pattern.match(obj["Key"])
                if not m:
                    continue
                matched.append({
                    "target_table":   fg["target_table"],
                    "s3_key":         obj["Key"],
                    "partition_value": m.group(partition_value_group),
                    "size_bytes":     obj["Size"],
                })

        # latest_per_partition: when a partition's folder holds one file per
        # dated snapshot (20260101.csv.gz, 20260201.csv.gz, ...), ingest only
        # the newest per partition. A YYYYMMDD in the key sorts lexically, so
        # the max s3_key per partition_value is the latest. Without this,
        # every historical file would load and repeatedly TRUNCATE+replace
        # the same leaf in nondeterministic order. Unused by PDL configs.
        if fg.get("latest_per_partition", False):
            latest: dict[str, dict[str, Any]] = {}
            for f in matched:
                pv = f["partition_value"]
                if pv not in latest or f["s3_key"] > latest[pv]["s3_key"]:
                    latest[pv] = f
            matched = list(latest.values())

        if not matched and not fg.get("optional", False):
            raise RuntimeError(
                f"required file_group {fg['name']!r} matched no files at "
                f"s3://{bucket}/{prefix}"
            )
        all_files.extend(matched)

    return all_files


# -----------------------------------------------------------------------------
# Catalog writes
# -----------------------------------------------------------------------------

def _write_catalog_rows(
    *,
    db_dsn: str,
    source: str,
    delivery_date: str,
    files_to_load: list[dict[str, Any]],
    file_groups: list[dict[str, Any]],
    pipeline_version: str,
) -> str:
    """INSERT pipeline_run + ingestion_run + N ingestion_file rows
    + pdl_delivery (PDL only). All in one transaction.

    pipeline_run — Finder always writes the parent row (DB-assigned UUID,
    captured via RETURNING) so the FK from ingestion_run is never dangling.

    Returns the new ingestion_run_id.
    """
    iso_delivery_date = delivery_date.replace("_", "-")  # yyyy_mm_dd → yyyy-mm-dd

    conn = connect(db_dsn)
    try:
        with conn:
            with conn.cursor() as cur:
                # pipeline_run — parent row for ingestion_run's FK.
                cur.execute(
                    """
                    INSERT INTO catalog.pipeline_run (
                        pipeline_name, pipeline_version, parameters,
                        status, started_at
                    ) VALUES (%s, %s, %s, %s, now())
                    RETURNING pipeline_run_id
                    """,
                    (
                        f"{source}_load",
                        pipeline_version,
                        json.dumps({"source": source, "delivery_date": delivery_date}),
                        "running",
                    ),
                )
                row = cur.fetchone()
                assert row is not None
                (pipeline_run_id,) = row

                # ingestion_run.
                cur.execute(
                    """
                    INSERT INTO catalog.ingestion_run (
                        pipeline_run_id, source_name, delivery_date,
                        status, started_at
                    ) VALUES (%s, %s, %s, 'started', now())
                    RETURNING ingestion_run_id
                    """,
                    (str(pipeline_run_id), source, iso_delivery_date),
                )
                row = cur.fetchone()
                assert row is not None
                (ingestion_run_id,) = row

                # ingestion_file rows.
                for f in files_to_load:
                    cur.execute(
                        """
                        INSERT INTO catalog.ingestion_file (
                            ingestion_run_id, target_table, s3_key,
                            partition_value, size_bytes, status
                        ) VALUES (%s, %s, %s, %s, %s, 'pending')
                        """,
                        (
                            str(ingestion_run_id),
                            f["target_table"],
                            f["s3_key"],
                            f["partition_value"],
                            f["size_bytes"],
                        ),
                    )

                # pdl_delivery (PDL-source only).
                if source.startswith("pdl_"):
                    _insert_pdl_delivery(
                        cur,
                        iso_delivery_date=iso_delivery_date,
                        files_to_load=files_to_load,
                        file_groups=file_groups,
                    )

        return str(ingestion_run_id)
    finally:
        conn.close()


def _insert_pdl_delivery(
    cur,
    *,
    iso_delivery_date: str,
    files_to_load: list[dict[str, Any]],
    file_groups: list[dict[str, Any]],
) -> None:
    """Write the PDL-specific catalog.pdl_delivery row.

    pdl_dataset_id is parsed from any 'MONTHLY_V_NN.N' substring in the
    discovered file keys. First deliveries (no delta_data) fall back to
    'unknown'. file_counts is a per-file_group breakdown. The terminal
    status ('success' / 'failed') and row_counts are written later by run.py.
    """
    pdl_dataset_id = "unknown"
    for f in files_to_load:
        m = _PDL_DATASET_RE.search(f["s3_key"])
        if m:
            pdl_dataset_id = m.group(1)
            break

    # Per-file_group counts. Group identity = target_table.
    file_counts = {fg["name"]: 0 for fg in file_groups}
    target_to_group = {fg["target_table"]: fg["name"] for fg in file_groups}
    for f in files_to_load:
        group_name = target_to_group.get(f["target_table"])
        if group_name is not None:
            file_counts[group_name] += 1

    cur.execute(
        """
        INSERT INTO catalog.pdl_delivery (
            delivery_date, pdl_dataset_id, complete_md_seen_at,
            file_counts, status, started_at
        ) VALUES (%s, %s, now(), %s, 'received', now())
        ON CONFLICT (delivery_date) DO UPDATE
            SET pdl_dataset_id      = EXCLUDED.pdl_dataset_id,
                complete_md_seen_at = EXCLUDED.complete_md_seen_at,
                file_counts         = EXCLUDED.file_counts,
                status              = EXCLUDED.status,
                started_at          = EXCLUDED.started_at,
                updated_at          = now()
        """,
        (iso_delivery_date, pdl_dataset_id, json.dumps(file_counts)),
    )


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

def _cli() -> int:
    configure_logging()
    parser = argparse.ArgumentParser(
        description="Discover files in S3 for one delivery and write catalog "
                    "rows. Prints ingestion_run_id on stdout for chaining "
                    "into the delivery_loader.",
    )
    parser.add_argument("--source", required=True,
                        help="source name; resolves to configs/<source>.yaml")
    parser.add_argument("--delivery-date", required=True,
                        help="literal yyyy_mm_dd delivery prefix (e.g. 2026_05_22)")
    parser.add_argument("--pipeline-version", default=_DEFAULT_PIPELINE_VERSION,
                        help=f"pipeline_version label written on the pipeline_run "
                             f"row (e.g. pin to git SHA / release tag; "
                             f"default: {_DEFAULT_PIPELINE_VERSION!r}).")
    args = parser.parse_args()

    db_dsn = os.environ.get("DATABASE_URL")
    if not db_dsn:
        logger.error("DATABASE_URL env var is required")
        return 2

    ingestion_run_id = discover_delivery(
        source=args.source,
        delivery_date=args.delivery_date,
        db_dsn=db_dsn,
        pipeline_version=args.pipeline_version,
    )
    print(ingestion_run_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
