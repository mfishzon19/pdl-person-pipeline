"""Seed the local S3 stand-in with a PDL-shaped delivery.

Runs as the one-shot `s3-init` compose service (inside the moto image, which
ships Python + boto3) after `fixture-load` has cached the sample. Produces the
layout the ingester expects, matching configs/pdl_full_local.yaml:

    s3://${LOCAL_BUCKET}/${DELIVERY_DATE}/data/part-00000.csv.gz   fixture data
    s3://${LOCAL_BUCKET}/${DELIVERY_DATE}/COMPLETED                sentinel

Full PDL deliveries also carry a `delta_data/` subtree (MERGED / DELETED /
OPTED_OUT records). The Finder treats those as optional, so the sample ships
only the full snapshot under `data/`.

Idempotent: re-running overwrites the same two objects.

Env (set by docker-compose.yml):
    S3_ENDPOINT      http://s3:5000
    LOCAL_BUCKET     pdl-ingest-local
    DELIVERY_DATE    yyyy_mm_dd (passed by `make dev-up-ingester`)
    FIXTURE_VERSION  cached fixture name (default pdl-person-sample-v1)
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import boto3


def main() -> int:
    endpoint = os.environ["S3_ENDPOINT"]
    bucket = os.environ["LOCAL_BUCKET"]
    delivery_date = os.environ.get("DELIVERY_DATE", "")
    if not delivery_date:
        print("DELIVERY_DATE must be set (yyyy_mm_dd); make dev-up-ingester passes it")
        return 1
    version = os.environ.get("FIXTURE_VERSION", "pdl-person-sample-v1")
    fixture = Path("/cache") / f"{version}.csv.gz"

    print("==> s3-init")
    # moto accepts any credentials; these only satisfy boto3's signer.
    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        region_name="us-east-1",
        aws_access_key_id="local",
        aws_secret_access_key="local",  # noqa: S106 (moto accepts any value)
    )

    existing = {b["Name"] for b in s3.list_buckets().get("Buckets", [])}
    if bucket in existing:
        print(f"  bucket exists: {bucket}")
    else:
        s3.create_bucket(Bucket=bucket)
        print(f"  bucket created: {bucket}")

    # Graceful degrade, matching fixture-load.sh: no fixture means no upload.
    if not fixture.is_file() or fixture.stat().st_size == 0:
        print(f"  WARN: {fixture} not present; skipping fixture upload.")
        print("  (See fixture-load logs for the upstream issue.)")
        return 0

    data_key = f"{delivery_date}/data/part-00000.csv.gz"
    sentinel_key = f"{delivery_date}/COMPLETED"
    print(f"  uploading delivery {delivery_date}/")
    s3.upload_file(str(fixture), bucket, data_key)
    # Zero-byte sentinel; the Finder's readiness check looks for exactly this key.
    s3.put_object(Bucket=bucket, Key=sentinel_key, Body=b"")

    for obj in s3.list_objects_v2(Bucket=bucket, Prefix=f"{delivery_date}/")["Contents"]:
        print(f"    s3://{bucket}/{obj['Key']}  ({obj['Size']} bytes)")
    print("==> s3-init done. Next: make ingest-pdl (or make pipeline-pdl)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
