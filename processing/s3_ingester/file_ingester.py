"""Per-file Ingester primitive (`file_ingester.py`).

Single entry point `ingest_file(...)` that loads one
S3 file into a Postgres raw table — either a partition leaf (when partition
args are supplied) or a flat table (when they're omitted). Both modes share
the same `catalog.ingestion_file` status lifecycle.

Called by `delivery_loader.py` once per pending `ingestion_file` row in a
delivery; also runnable directly via the CLI below for ad-hoc single-file
testing.

Load path: the file's bytes are fetched from S3 with boto3 (honors
AWS_ENDPOINT_URL, so local S3 works unchanged), gunzipped if needed, and
loaded into the target table with `COPY ... FROM STDIN` on the same
psycopg2 connection. No server-side Postgres S3 extension is required. See
docs/design/02_pipeline_design.md Section 6.

Spec:
    - This module raises on any failure; caller decides whether to retry
      (re-running the delivery is safe — each file is TRUNCATE+COPY).
    - All catalog writes for *one file* live here.

Local CLI:
    DATABASE_URL='postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl' \\
    AWS_ENDPOINT_URL=http://localhost:9000 \\
    AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=local \\
    python -m processing.s3_ingester.file_ingester \\
        --ingestion-file-id <uuid> \\
        --schema raw --table pdl_person \\
        --column-list payload \\
        --copy-options "(FORMAT csv, DELIMITER E'\\x01', QUOTE E'\\x02')" \\
        --bucket pdl-ingest-local \\
        --s3-key 2026_05_22/data/part-00086.csv.gz \\
        --region us-east-1 \\
        --partition-column partition_id \\
        --partition-value 86 \\
        --partition-value-type smallint
"""

from __future__ import annotations

import argparse
import gzip
import io
import logging
import os
from collections.abc import Callable

import boto3
from psycopg2 import sql

from processing.common.db import connect
from processing.common.logging_setup import configure_logging

logger = logging.getLogger(__name__)

# Whitelist of partition-column types we know how to render as a typed
# literal. Not a security boundary — partition_value_type comes from
# controlled config. Acts as a typo guard so 'smalint' raises a clean
# ValueError instead of a cryptic Postgres syntax error mid-DDL.
_ALLOWED_PARTITION_TYPES = frozenset({
    "smallint", "integer", "bigint",
    "text", "varchar",
})

# Postgres identifier max length (NAMEDATALEN - 1).
_PG_IDENT_MAX = 63


# -----------------------------------------------------------------------------
# Public entry point
# -----------------------------------------------------------------------------

def ingest_file(
    *,
    ingestion_file_id: str,
    schema: str,
    table: str,
    column_list: str,
    copy_options: str,
    bucket: str,
    s3_key: str,
    region: str,
    db_dsn: str,
    partition_column: str | None = None,
    partition_value: str | None = None,
    partition_value_type: str | None = None,
) -> int:
    """Atomically load one S3 file into a raw table and update catalog.

    Two modes, picked by whether the three partition args are supplied:

      Partitioned mode (all three set):
          target = f"{table}_p_{partition_value-with-hyphens-as-underscores}"
          tx2 also runs CREATE TABLE IF NOT EXISTS leaf PARTITION OF + ALTER
          ALTER COLUMN ... SET DEFAULT before the COPY.

      Flat mode (all three None):
          target = table
          tx2 just runs the TRUNCATE + COPY.

    The three transactions on the happy path:

      tx1 — UPDATE catalog.ingestion_file SET status='loading',
                                              load_started_at=now()
            (commits immediately so observers see in-flight state)

      tx2 — [partitioned only] CREATE TABLE IF NOT EXISTS leaf ...;
                               ALTER TABLE leaf ... SET DEFAULT ...;
            TRUNCATE leaf; COPY leaf FROM STDIN (bytes fetched from S3);
            UPDATE catalog.ingestion_file SET status='success',
                                              row_count=..., load_ended_at=now()
            (atomic — RAISE inside any step rolls all of tx2 back)

      tx3 — only on tx2 exception:
            UPDATE catalog.ingestion_file SET status='failed',
                                              error_message=..., load_ended_at=now()
            (fresh transaction, then re-raise so the caller sees the failure)

    Args:
      ingestion_file_id:    catalog.ingestion_file.ingestion_file_id (uuid).
                            Finder inserted this row with status='pending'
                            before the Ingester is invoked.
      schema:               Target schema, e.g. 'raw'. Used as the parent
                            table's schema in partitioned mode.
      table:                Parent table in partitioned mode (leaf is derived
                            from this), or the target table in flat mode.
      column_list:          Columns the COPY targets, e.g. 'payload'.
      copy_options:         Postgres COPY options string. Must include the
                            surrounding parens that modern COPY syntax
                            requires, e.g.
                            "(FORMAT csv, DELIMITER E'\\x01', QUOTE E'\\x02')".
                            Substituted verbatim into
                            `COPY ... FROM STDIN WITH <copy_options>`.
      bucket, s3_key, region: S3 location. Objects ending in `.gz` (or with
                            Content-Encoding: gzip) are gunzipped first.
      db_dsn:               Postgres connection string (libpq DSN or URI).
      partition_column:     Partition column name, e.g. 'partition_id'.
                            Required iff partitioned mode.
      partition_value:      Text-formatted partition value, e.g. '86' or
                            'some-text-key'. Required iff partitioned mode.
      partition_value_type: One of {'smallint','integer','bigint','text',
                            'varchar'}; determines whether the literal gets
                            a type cast in DDL. Required iff partitioned mode.

    Returns:
      Row count loaded (SELECT count(*) on the target after the COPY).

    Raises:
      ValueError                 — partition args partially supplied; derived
                                   leaf name exceeds 63 bytes; unsupported
                                   partition_value_type.
      psycopg2.Error subclasses  — any DB-side failure. Propagated AFTER the
                                   failure UPDATE in tx3.
    """
    partition = _validate_partition_args(
        partition_column, partition_value, partition_value_type,
    )

    # Compute target table + any pre-COPY DDL up front, with narrowed types.
    # The closure below then has no None / branching to deal with.
    if partition is not None:
        pcol, pval, ptype = partition
        target_table = f"{table}_p_{pval.replace('-', '_')}"
        if len(target_table) > _PG_IDENT_MAX:
            raise ValueError(
                f"derived leaf name {target_table!r} exceeds "
                f"{_PG_IDENT_MAX}-byte identifier limit"
            )
        typed_literal = _typed_literal(pval, ptype)
        pre_copy_ddl: list[sql.Composable] = [
            sql.SQL(
                "CREATE TABLE IF NOT EXISTS {schema}.{leaf} "
                "PARTITION OF {schema}.{parent} "
                "FOR VALUES IN ({literal})"
            ).format(
                schema=sql.Identifier(schema),
                leaf=sql.Identifier(target_table),
                parent=sql.Identifier(table),
                literal=typed_literal,
            ),
            sql.SQL(
                "ALTER TABLE {schema}.{leaf} "
                "ALTER COLUMN {col} SET DEFAULT {literal}"
            ).format(
                schema=sql.Identifier(schema),
                leaf=sql.Identifier(target_table),
                col=sql.Identifier(pcol),
                literal=typed_literal,
            ),
        ]
    else:
        target_table = table
        pre_copy_ddl = []

    def action(cur) -> tuple[int, int]:
        for ddl in pre_copy_ddl:
            cur.execute(ddl)

        # TRUNCATE + COPY-from-STDIN inside this same tx; returns
        # (imported_count, actual_count). The two columns are preserved
        # separately on ingestion_file so source-side vs destination-side
        # counts can diverge in the future without a schema change.
        return _copy_from_s3(
            cur, schema, target_table, column_list, copy_options,
            bucket, s3_key, region,
        )

    conn = connect(db_dsn)
    try:
        return _run_with_catalog_lifecycle(conn, ingestion_file_id, action)
    finally:
        conn.close()


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

def _validate_partition_args(
    partition_column: str | None,
    partition_value: str | None,
    partition_value_type: str | None,
) -> tuple[str, str, str] | None:
    """Return (column, value, value_type) for partitioned mode, None for flat.

    The asserts narrow the optional types for the type-checker once the
    set-count check has guaranteed all three are non-None. Raises ValueError
    on partial supply.
    """
    args = (partition_column, partition_value, partition_value_type)
    set_count = sum(arg is not None for arg in args)
    if set_count == 0:
        return None
    if set_count == 3:
        assert partition_column is not None
        assert partition_value is not None
        assert partition_value_type is not None
        return (partition_column, partition_value, partition_value_type)
    raise ValueError(
        "partition_column, partition_value, partition_value_type must all be "
        "set together (partitioned mode) or all None (flat-table mode); got "
        f"partition_column={partition_column!r}, "
        f"partition_value={partition_value!r}, "
        f"partition_value_type={partition_value_type!r}"
    )


def _typed_literal(partition_value: str, partition_value_type: str) -> sql.Composable:
    """Build a Composable SQL fragment for FOR VALUES IN / SET DEFAULT.

    Not a security boundary — partition_value comes from controlled config,
    not user input. Uses psycopg2.sql for quoting (handles hyphens in
    text partition keys); the type whitelist catches typos in partition_value_type
    before they hit Postgres.
    """
    if partition_value_type in {"smallint", "integer", "bigint"}:
        return sql.SQL("{val}::{typ}").format(
            val=sql.Literal(partition_value),
            typ=sql.SQL(partition_value_type),
        )
    if partition_value_type in {"text", "varchar"}:
        return sql.Literal(partition_value)
    raise ValueError(
        f"unsupported partition_value_type {partition_value_type!r}; "
        f"must be one of {sorted(_ALLOWED_PARTITION_TYPES)}"
    )


def _copy_from_s3(
    cur,
    schema: str,
    target_table: str,
    column_list: str,
    copy_options: str,
    bucket: str,
    s3_key: str,
    region: str,
) -> tuple[int, int]:
    """Load one S3 object into `schema.target_table` via COPY FROM STDIN.

      - TRUNCATE the target (per-file replace semantics)
      - Stream the file's bytes into target via COPY ... FROM STDIN
      - Return SELECT COUNT(*) from the target

    The bytes are fetched from S3 via boto3 (which honors AWS_ENDPOINT_URL
    → local S3 for local runs). Gzip is detected by key suffix or the object's
    Content-Encoding header, because uploads (e.g. s3-init's boto3
    `upload_file`) don't always set Content-Encoding.

    Trade-off: the whole object is downloaded into memory before the COPY,
    so peak RAM is bounded by the largest single file (decompressed). PDL
    splits a delivery into many modest part files, so this is fine on a
    laptop; loading a full delivery is a sequence of these, not one big buffer.
    """
    qualified = f"{schema}.{target_table}"

    s3 = boto3.client("s3", region_name=region)
    obj = s3.get_object(Bucket=bucket, Key=s3_key)
    body = obj["Body"].read()

    # Decompress if gzipped (suffix sniff or Content-Encoding header).
    if s3_key.endswith(".gz") or obj.get("ContentEncoding") == "gzip":
        body = gzip.decompress(body)

    # TRUNCATE gives per-file replace semantics (re-runs are idempotent).
    cur.execute(sql.SQL("TRUNCATE TABLE {}").format(sql.Identifier(schema, target_table)))

    # column_list comes from controlled config ('payload'), and
    # copy_options has the surrounding parens the modern COPY syntax
    # requires. We pass both through verbatim.
    copy_sql = f"COPY {qualified} ({column_list}) FROM STDIN WITH {copy_options}"
    cur.copy_expert(copy_sql, io.BytesIO(body))

    cur.execute(sql.SQL("SELECT COUNT(*) FROM {}").format(sql.Identifier(schema, target_table)))
    (row_count,) = cur.fetchone()
    # COPY FROM STDIN has no separate source-reported "imported" count —
    # return the same value in both slots to keep the (imported, actual)
    # tuple shape the catalog lifecycle expects.
    return int(row_count), int(row_count)


def _run_with_catalog_lifecycle(
    conn,
    ingestion_file_id: str,
    load_action: Callable[[object], tuple[int, int]],
) -> int:
    """Three-transaction catalog-status lifecycle around a load action.

      tx1 — UPDATE ingestion_file SET status='loading', load_started_at=now()
            (commits immediately so observers see in-flight state).

      tx2 — load_action(cur) returns (imported_count, actual_count); on
            success UPDATE status='success', expected_row_count=imported,
            row_count=actual, load_ended_at=now() — atomic with the work.

      tx3 — only on tx2 exception: UPDATE status='failed', error_message=...,
            load_ended_at=now() in a fresh transaction; re-raise.
    """
    # tx1 — mark loading.
    with conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE catalog.ingestion_file "
                "SET status='loading', load_started_at=now() "
                "WHERE ingestion_file_id = %s",
                (ingestion_file_id,),
            )

    # tx2 — atomic load + success update.
    try:
        with conn:
            with conn.cursor() as cur:
                imported_count, actual_count = load_action(cur)
                cur.execute(
                    "UPDATE catalog.ingestion_file "
                    "SET status='success', "
                    "    expected_row_count=%s, row_count=%s, "
                    "    load_ended_at=now() "
                    "WHERE ingestion_file_id = %s",
                    (imported_count, actual_count, ingestion_file_id),
                )
        return actual_count
    except Exception as exc:
        # tx3 — fresh tx for the failure update; re-raise so the caller sees it.
        with conn:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE catalog.ingestion_file "
                    "SET status='failed', error_message=%s, load_ended_at=now() "
                    "WHERE ingestion_file_id = %s",
                    (str(exc), ingestion_file_id),
                )
        raise


# -----------------------------------------------------------------------------
# CLI — for ad-hoc single-file loads. delivery_loader / run.py call
# ingest_file() directly for whole deliveries.
# -----------------------------------------------------------------------------

def _cli() -> int:
    configure_logging()
    parser = argparse.ArgumentParser(
        description="Load one S3 file into a Postgres raw table "
                    "(partitioned leaf or flat table).",
    )
    parser.add_argument("--ingestion-file-id", required=True,
                        help="catalog.ingestion_file uuid")
    parser.add_argument("--schema", required=True,
                        help="target schema, e.g. raw")
    parser.add_argument("--table", required=True,
                        help="target table; parent in partitioned mode")
    parser.add_argument("--column-list", required=True,
                        help="COPY column list, e.g. payload")
    parser.add_argument("--copy-options", required=True,
                        help="COPY options string")
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--s3-key", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--partition-column",
                        help="partition column name; omit for flat-table mode")
    parser.add_argument("--partition-value",
                        help="partition value; omit for flat-table mode")
    parser.add_argument("--partition-value-type",
                        choices=sorted(_ALLOWED_PARTITION_TYPES),
                        help="partition column type; omit for flat-table mode")
    args = parser.parse_args()

    db_dsn = os.environ.get("DATABASE_URL")
    if not db_dsn:
        logger.error("DATABASE_URL env var is required")
        return 2

    row_count = ingest_file(
        ingestion_file_id=args.ingestion_file_id,
        schema=args.schema,
        table=args.table,
        column_list=args.column_list,
        copy_options=args.copy_options,
        bucket=args.bucket,
        s3_key=args.s3_key,
        region=args.region,
        db_dsn=db_dsn,
        partition_column=args.partition_column,
        partition_value=args.partition_value,
        partition_value_type=args.partition_value_type,
    )
    print(row_count)
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
