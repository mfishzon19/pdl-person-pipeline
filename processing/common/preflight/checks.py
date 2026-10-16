"""Delivery readiness checks against an S3 prefix.

See `docs/design/common_libraries.md`.

Note: the S3 ingester's file_ingester gunzips by key suffix, so the
Content-Encoding check is advisory for it; it matters for any consumer
that relies on the header (e.g. streaming decompression by HTTP clients).
"""

from __future__ import annotations

import re
from collections.abc import Iterable

from botocore.exceptions import ClientError

DEFAULT_SENTINEL_NAME = "COMPLETED"

# PDL's `part-NNNNN.csv.gz` shape. The first capturing group must be
# the integer partition id. Override for sources with different
# filename conventions.
DEFAULT_PART_PATTERN: re.Pattern[str] = re.compile(r"^part-(\d+)\.csv\.gz$")


def _snapshot_root(prefix: str) -> str:
    """Drop the last folder from a prefix.

    `2026_05_22/data/` -> `2026_05_22/`. The COMPLETED sentinel sits
    at the delivery root, one level above the data folder.

    A single-segment prefix like `data/` returns `""`, which makes
    `check_completed_sentinel` look at the bucket root. Pass the full
    `<delivery_date>/<folder>/` shape to avoid that.
    """
    trimmed = prefix.rstrip("/")
    parent, _, _ = trimmed.rpartition("/")
    return f"{parent}/" if parent else ""


def check_completed_sentinel(
    s3,
    bucket: str,
    prefix: str,
    *,
    sentinel_name: str = DEFAULT_SENTINEL_NAME,
) -> bool:
    """Return True if the delivery's sentinel marker exists in S3.

    Returns False (without raising) if the marker is missing — that
    means the delivery isn't finished uploading yet, so the caller
    should wait. Any other S3 error bubbles up.
    """
    key = f"{_snapshot_root(prefix)}{sentinel_name}"
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return True
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code")
        if code in ("404", "NoSuchKey", "NotFound"):
            return False
        raise


def list_partition_ids(
    s3,
    bucket: str,
    prefix: str,
    *,
    key_pattern: re.Pattern[str] = DEFAULT_PART_PATTERN,
) -> list[int]:
    """Return the integer partition ids of files under `prefix`.

    Paginates `list_objects_v2`. Only keys whose filename matches
    `key_pattern` (capturing group 1 = id) are included. Sorted
    ascending. Returns `[]` if no matching files are found.
    """
    paginator = s3.get_paginator("list_objects_v2")
    ids: list[int] = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents") or []:
            filename = obj["Key"].rsplit("/", 1)[-1]
            m = key_pattern.match(filename)
            if m:
                ids.append(int(m.group(1)))
    return sorted(ids)


def verify_object_encoding(s3, bucket: str, key: str) -> None:
    """Raise if an S3 object is missing `Content-Encoding: gzip`.

    Consumers that decide whether to decompress from this header
    (not the filename) fail partway through with a confusing UTF-8
    error when it's missing — better to fail fast here with a clear
    message pointing at the offending key.
    """
    head = s3.head_object(Bucket=bucket, Key=key)
    encoding = head.get("ContentEncoding")
    if encoding != "gzip":
        raise RuntimeError(
            f"s3://{bucket}/{key} is missing Content-Encoding: gzip "
            f"(got {encoding!r}). Header-driven gunzip will fail with "
            f"the '0x8b UTF-8' error. Fix the object metadata upstream."
        )


def verify_content_encoding(s3, bucket: str, keys: Iterable[str]) -> None:
    """Run `verify_object_encoding` over a list of keys, stop on the
    first failure.

    Takes full keys (not `prefix` + ids) so each source can build the
    list however its filename convention demands.
    """
    for key in keys:
        verify_object_encoding(s3, bucket, key)
