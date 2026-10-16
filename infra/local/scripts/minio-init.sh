#!/bin/sh
# Provisions the local MinIO with a PDL-shaped delivery layout so
# `python -m processing.s3_ingester.run` works end-to-end against it.
#
# Idempotent: bucket creation + uploads use mc's --quiet flag and tolerate
# "already exists" responses. Re-running on a warm minio is a no-op.
#
# Layout produced (matches the PDL delivery bucket convention):
#   s3://${LOCAL_BUCKET}/${DELIVERY_DATE}/data/part-00000.csv.gz   ← fixture data
#   s3://${LOCAL_BUCKET}/${DELIVERY_DATE}/COMPLETED                ← sentinel
#
# Full PDL deliveries also have a `delta_data/` subtree with per-record
# diffs (MERGED_RECORDS / DELETED_RECORDS / OPTED_OUT_RECORDS). We don't
# ship those in the local fixture — Finder treats them as optional, so the
# pipeline runs end-to-end with just the full-snapshot file under `data/`.
#
# Inputs (from compose env):
#   MINIO_ENDPOINT       http://minio:9000
#   MINIO_ROOT_USER      minio_local
#   MINIO_ROOT_PASSWORD  minio_local_dev
#   LOCAL_BUCKET         pdl-ingest-local
#   DELIVERY_DATE        yyyy_mm_dd (set by `make dev-up-ingester` from the Makefile)
#
# Cached fixture: /cache/${FIXTURE_VERSION}.csv.gz (populated by fixture-load —
# by default a copy of the committed synthetic sample in infra/local/fixtures/).

set -e

FIXTURE_VERSION="${FIXTURE_VERSION:-pdl-person-sample-v1}"
: "${DELIVERY_DATE:?DELIVERY_DATE must be set (yyyy_mm_dd); make dev-up-ingester passes it}"
FIXTURE_FILE="/cache/${FIXTURE_VERSION}.csv.gz"

echo "==> minio-init"

# Register the mc alias (compose already waited for MinIO's healthcheck).
mc alias set local "${MINIO_ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"

# Create bucket (idempotent).
if mc ls "local/${LOCAL_BUCKET}" >/dev/null 2>&1; then
  echo "  bucket exists: ${LOCAL_BUCKET}"
else
  mc mb "local/${LOCAL_BUCKET}"
  echo "  bucket created: ${LOCAL_BUCKET}"
fi

# Skip upload if fixture file wasn't downloaded (graceful degrade,
# matches fixture-load.sh non-fatal behavior).
if [ ! -s "${FIXTURE_FILE}" ]; then
  echo "  WARN: ${FIXTURE_FILE} not present — skipping fixture upload."
  echo "  (See fixture-load logs for the upstream issue.)"
  exit 0
fi

# Upload fixture as a single PDL part file + the COMPLETED sentinel.
# Path layout MUST match configs/pdl_full_local.yaml's key_pattern:
#   ^{delivery_date}/data/part-(?P<partition_id>\d{5})\.csv\.gz$
echo "  uploading delivery ${DELIVERY_DATE}/"
mc cp --quiet "${FIXTURE_FILE}" "local/${LOCAL_BUCKET}/${DELIVERY_DATE}/data/part-00000.csv.gz"

# Sentinel is a zero-byte object whose key ends in `COMPLETED` (no
# leading dot, no extension). Finder's readiness check looks for exactly
# this key — see sentinel.key_pattern in configs/pdl_full_local.yaml.
echo -n "" | mc pipe "local/${LOCAL_BUCKET}/${DELIVERY_DATE}/COMPLETED"

echo "  uploaded:"
mc ls --recursive "local/${LOCAL_BUCKET}/${DELIVERY_DATE}/"

echo "==> minio-init done"
echo ""
echo "Try a local ingester run:"
echo "  make ingest-pdl     # wraps the command below"
echo "  make pipeline-pdl   # ingest-pdl + dbt-pdl (full chain)"
echo ""
echo "  (host, conda activate pdl_test; make ingest-pdl sets the env below)"
echo "  AWS_ENDPOINT_URL=http://localhost:9000 \\"
echo "  AWS_ACCESS_KEY_ID=${MINIO_ROOT_USER} AWS_SECRET_ACCESS_KEY=${MINIO_ROOT_PASSWORD} \\"
echo "  DATABASE_URL=postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl \\"
echo "    python -m processing.s3_ingester.run \\"
echo "      --source pdl_full_local \\"
echo "      --delivery-date ${DELIVERY_DATE} \\"
echo "      --max-concurrency 2"
