"""S3 helpers used by the ETL.

Thin wrappers around the boto3 S3 client with consistent error
translation for simple reads.

Two patterns covered:

    list_keys(bucket, prefix, region)  -> iterator of key strings
    get_object_bytes(bucket, key, region) -> bytes

Endpoint override: boto3 honors the AWS_ENDPOINT_URL env var, so the
local-dev MinIO docker stack (export AWS_ENDPOINT_URL=http://localhost:9000,
as the Makefile ingester targets do) works through these helpers without
code changes.
"""

from __future__ import annotations

from collections.abc import Iterator

import boto3
import botocore.exceptions

from processing.common.aws.errors import (
    AccessDenied,
    AWSOpsError,
    NotFound,
    TransientError,
)


def _client(region: str | None):
    return (
        boto3.client("s3", region_name=region)
        if region
        else boto3.client("s3")
    )


def _translate(exc: botocore.exceptions.ClientError) -> AWSOpsError:
    code = exc.response.get("Error", {}).get("Code", "")
    if code in {"NoSuchKey", "NoSuchBucket", "404"}:
        return NotFound(str(exc))
    if code in {"AccessDenied", "403", "AllAccessDisabled"}:
        return AccessDenied(str(exc))
    if code in {"SlowDown", "ServiceUnavailable", "InternalError", "RequestTimeout", "Throttling"}:
        return TransientError(str(exc))
    return AWSOpsError(str(exc))


def list_keys(
    bucket: str,
    prefix: str = "",
    region: str | None = None,
) -> Iterator[str]:
    """Yield every object key under `bucket/prefix` (paginated under the hood).

    Raises:
        NotFound        bucket does not exist.
        AccessDenied    no s3:ListBucket on the prefix.
        TransientError  throttling / 5xx.
        AWSOpsError     anything else.
    """
    s3 = _client(region)
    paginator = s3.get_paginator("list_objects_v2")
    try:
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                yield obj["Key"]
    except botocore.exceptions.ClientError as exc:
        raise _translate(exc) from exc


def get_object_bytes(
    bucket: str,
    key: str,
    region: str | None = None,
) -> bytes:
    """Download an S3 object as bytes.

    Reads the whole object into memory — appropriate for small artifacts
    (fixtures, configs, sentinels) and single PDL part files; don't use
    it to buffer many files at once.

    Raises:
        NotFound        key does not exist.
        AccessDenied    no s3:GetObject on the key.
        TransientError  throttling / 5xx.
        AWSOpsError     anything else.
    """
    s3 = _client(region)
    try:
        resp = s3.get_object(Bucket=bucket, Key=key)
        return resp["Body"].read()
    except botocore.exceptions.ClientError as exc:
        raise _translate(exc) from exc
