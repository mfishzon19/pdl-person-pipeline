"""boto3 wrappers for AWS services used by the ETL.

Public API (import from this module):

    Secrets Manager:
        get_secret(name, field=None, region=None, parse_json=True)

    S3:
        list_keys(bucket, prefix, region)         -> iter[str]
        get_object_bytes(bucket, key, region)     -> bytes

    Exceptions (catch these, not botocore.*):
        AWSOpsError              base
        NotFound                 resource not found (NoSuchKey, etc.)
        AccessDenied             403 / AccessDenied
        TransientError           throttling / 5xx — retry-worthy

The S3 ingester's finder / file_ingester build their own boto3 clients
(they need paginated metadata and streaming bodies); these helpers cover
simpler one-off reads.
"""

from processing.common.aws.errors import (
    AccessDenied,
    AWSOpsError,
    NotFound,
    TransientError,
)
from processing.common.aws.s3 import get_object_bytes, list_keys
from processing.common.aws.secrets import get_secret

__all__ = [
    "get_secret",
    "list_keys",
    "get_object_bytes",
    "AWSOpsError",
    "NotFound",
    "AccessDenied",
    "TransientError",
]
