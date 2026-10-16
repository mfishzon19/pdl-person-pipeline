"""Pre-flight delivery readiness checks (see docs/design/common_libraries.md).

Standalone checks a caller can run against an S3 prefix before loading:

  - `check_completed_sentinel` — is the delivery finished uploading?
  - `list_partition_ids`       — what files are in the delivery?
  - `verify_object_encoding`   — will Postgres be able to read a key?
  - `verify_content_encoding`  — `verify_object_encoding` over a list.

Source-agnostic. The `s3_ingester` Finder does its own sentinel check from
the YAML config and does not call these.
"""

from processing.common.preflight.checks import (
    DEFAULT_PART_PATTERN,
    DEFAULT_SENTINEL_NAME,
    check_completed_sentinel,
    list_partition_ids,
    verify_content_encoding,
    verify_object_encoding,
)

__all__ = [
    "DEFAULT_PART_PATTERN",
    "DEFAULT_SENTINEL_NAME",
    "check_completed_sentinel",
    "list_partition_ids",
    "verify_content_encoding",
    "verify_object_encoding",
]
