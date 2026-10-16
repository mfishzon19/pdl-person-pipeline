#!/usr/bin/env bash
# Resolves the PDL person fixture and loads it into raw.pdl_person.
#
# Runs from the fixture-load container during `docker compose up`.
# Idempotent: re-runs reuse the cached file, and the COPY itself is
# wrapped in TRUNCATE + COPY inside one transaction — every run starts
# from a fresh leaf, so duplicate-key conflicts can't accumulate.
#
# Inputs (from compose env):
#   FIXTURE_VERSION    fixture slug (default "pdl-person-sample-v1")
#   FIXTURE_URL        optional HTTPS URL of a fixture .csv.gz — an override
#                      for your own sanitized sample (sanitize-pdl-fixture.py).
#   PGHOST             postgres hostname (compose service: "postgres")
#   PGUSER             postgres user (pdl_etl)
#   PGPASSWORD         postgres password (pdl_etl_dev)
#   PGDATABASE         postgres db (pdl_etl)
#
# Cache:   /cache/${FIXTURE_VERSION}.csv.gz     (infra/local/fixtures-cache/, gitignored)
# Bundled: /fixtures/${FIXTURE_VERSION}.csv.gz  (infra/local/fixtures/, committed)
#
# Resolution order:
#   1. cached file in fixtures-cache/
#   2. download from FIXTURE_URL (when set)
#   3. the committed FULLY SYNTHETIC sample in infra/local/fixtures/
#      (built by generate-sample-fixture.py — no real people or companies)
#   4. nothing found → skip (exit 0)
# Steps 2–3 leave the file in the cache, where minio-init picks it up.
# The cache wins on re-runs: `make dev-reset` clears it, so a new
# FIXTURE_URL or a regenerated committed sample takes effect after a reset.

set -euo pipefail

FIXTURE_VERSION="${FIXTURE_VERSION:-pdl-person-sample-v1}"
FIXTURE_FILE="${FIXTURE_VERSION}.csv.gz"
FIXTURE_URL="${FIXTURE_URL:-}"
CACHE_PATH="/cache/${FIXTURE_FILE}"
BUNDLED_PATH="/fixtures/${FIXTURE_FILE}"

mkdir -p /cache

echo "==> fixture-load (${FIXTURE_VERSION})"

# Copies the committed synthetic sample for this FIXTURE_VERSION into the
# cache. Returns non-zero when no committed file exists for the version.
use_bundled() {
  if [[ -s "${BUNDLED_PATH}" ]]; then
    cp "${BUNDLED_PATH}" "${CACHE_PATH}"
    echo "  using committed synthetic sample: infra/local/fixtures/${FIXTURE_FILE}"
    echo "  (fully synthetic PDL-shaped records — no real people or companies)"
    return 0
  fi
  return 1
}

skip_no_fixture() {
  cat <<EOF

NOTICE: no PDL fixture available — skipping fixture load.

  No cached file at infra/local/fixtures-cache/${FIXTURE_FILE}, no usable
  FIXTURE_URL, and no committed sample at infra/local/fixtures/${FIXTURE_FILE}
  (FIXTURE_VERSION=${FIXTURE_VERSION}). Schema migrations applied
  successfully; raw.pdl_person will just be empty (and minio-init will
  create an empty bucket).

To load sample data, either:
  - unset FIXTURE_VERSION to use the committed synthetic sample, or
  - set FIXTURE_URL to an HTTPS URL of a PDL .csv.gz (gzipped JSONL, one
    PDL person per line) and re-run \`make dev-up\`, or
  - drop the file at infra/local/fixtures-cache/${FIXTURE_FILE}
    and re-run \`docker compose up fixture-load\`.

EOF
  echo "==> fixture-load skipped"
  exit 0
}

# Step 1 — cache, else FIXTURE_URL, else committed synthetic sample, else skip.
if [[ -s "${CACHE_PATH}" ]]; then
  echo "  cache hit: ${CACHE_PATH} ($(stat -c%s "${CACHE_PATH}" 2>/dev/null || stat -f%z "${CACHE_PATH}") bytes)"
elif [[ -z "${FIXTURE_URL}" ]]; then
  use_bundled || skip_no_fixture
else
  # The fixture-load container uses postgres:18.3 (gives us psql + libpq
  # for the \copy step). The image is slim — it ships NEITHER curl NOR
  # ca-certificates by default. We need:
  #   - curl              for the HTTPS download
  #   - ca-certificates   so curl's TLS verification has root CAs to trust
  # apt-get is idempotent (no-op if already installed) and fast (~5s).
  echo "==> installing curl + ca-certificates (one-time, ~5s)"
  apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      curl ca-certificates >/dev/null

  echo "  downloading from ${FIXTURE_URL}"
  if ! curl --fail --silent --show-error --location \
            --output "${CACHE_PATH}" \
            --connect-timeout 10 --max-time 120 \
            "${FIXTURE_URL}"; then
    rm -f "${CACHE_PATH}"
    cat <<EOF

WARNING: fixture download failed — falling back to the committed sample.

Possible causes:
  - FIXTURE_URL ('${FIXTURE_URL}') is wrong or not publicly readable.
  - Engineer is offline / behind a strict proxy.

Workaround:
  - Drop a fixture CSV.gz at infra/local/fixtures-cache/${FIXTURE_FILE}
    manually and re-run \`docker compose up fixture-load\`.

EOF
    use_bundled || skip_no_fixture
  else
    echo "  cached at ${CACHE_PATH} ($(stat -c%s "${CACHE_PATH}" 2>/dev/null || stat -f%z "${CACHE_PATH}") bytes)"
  fi
fi

# Step 1b — skip direct-load if the ingester profile is active.
#
# When SKIP_RAW_LOAD=1, this script only CACHES the fixture in the
# shared cache directory (so minio-init can upload it to MinIO). The
# ingester engineer then runs `make ingest-pdl`, which exercises
# s3_ingester.run end-to-end and populates raw.pdl_person via the real
# Finder → Loader → Projection chain. Set by `make dev-up-ingester`.
if [[ "${SKIP_RAW_LOAD:-0}" == "1" ]]; then
  echo "  SKIP_RAW_LOAD=1 — fixture cached only, raw.pdl_person left empty"
  echo "  (run \`make ingest-pdl\` to populate via the ingester)"
  echo "==> fixture-load done"
  exit 0
fi

# Step 2 — load into raw.pdl_person.
#
# Schema for raw.pdl_person (per V2__raw_baseline.sql):
#   partition_id smallint    NOT NULL
#   payload      jsonb       NOT NULL
#   loaded_at    timestamptz NOT NULL DEFAULT now()
#   ) PARTITION BY LIST (partition_id);
#
# Fixture file format: gzipped JSONL — one PDL JSON object per line
# (generate-sample-fixture.py builds the committed synthetic sample;
# sanitize-pdl-fixture.py turns a licensed delivery file into one).
#
# Postgres COPY trick (matches the ingester's pdl_full copy_options):
#   FORMAT csv, DELIMITER E'\x01', QUOTE E'\x02'
# Neither 0x01 (SOH) nor 0x02 (STX) appears in JSON, so each line is
# treated as a single un-split CSV field landing into `payload`.
#
# Partition handling: the ingester creates a leaf per part file
# (partition_id = file index). For the fixture, we use partition_id=0 — one leaf.

echo "  loading raw.pdl_person from fixture"
PG_CONN="host=${PGHOST} port=${PGPORT:-5432} user=${PGUSER} dbname=${PGDATABASE}"

# Sanity: bail if raw.pdl_person doesn't exist (Flyway didn't run).
if ! psql "${PG_CONN}" --no-psqlrc -tA \
       -c "SELECT 1 FROM information_schema.tables WHERE table_schema='raw' AND table_name='pdl_person';" \
     | grep -q 1; then
  echo "ERROR: raw.pdl_person does not exist. Flyway init must have failed."
  echo "       Inspect with: docker compose logs flyway-init"
  exit 1
fi

# Idempotent reload: create-or-attach leaf, TRUNCATE, COPY inside one txn.
gunzip --keep --force "${CACHE_PATH}"
UNCOMPRESSED="${CACHE_PATH%.gz}"

psql "${PG_CONN}" --no-psqlrc --set=ON_ERROR_STOP=on <<SQL
BEGIN;
-- Create the partition-0 leaf if missing (the ingester does this per
-- part file; for fixtures we always use partition_id=0).
--
-- Leaf name MUST match the ingester's derived format: the ingester
-- builds the leaf name from the part-file index zero-padded to five
-- digits (see processing/s3_ingester/file_ingester.py — target_table =
-- f"{table}_p_{pval.replace('-', '_')}"; pval comes from the part-NNNNN
-- file index). For part-00000.csv.gz that yields pdl_person_p_00000.
-- If we used a different name here (e.g. pdl_person_p_0), then after
-- a 'make dev-up' followed by 'make dev-up-ingester' without dev-reset,
-- the ingester's CREATE TABLE ... FOR VALUES IN (0) would collide with
-- the leftover p_0 leaf bound to the same partition value.
CREATE TABLE IF NOT EXISTS raw.pdl_person_p_00000
    PARTITION OF raw.pdl_person FOR VALUES IN (0);

-- Per-leaf DEFAULT for partition_id. The parent table declares the
-- column NOT NULL with no default; without this ALTER, a COPY into the
-- leaf that targets only \`payload\` writes NULL into partition_id and
-- the constraint trips. Matches the ingester pattern in
-- processing/s3_ingester/file_ingester.py (per-leaf SET DEFAULT for the
-- partition column before the COPY).
ALTER TABLE raw.pdl_person_p_00000 ALTER COLUMN partition_id SET DEFAULT 0;

TRUNCATE TABLE raw.pdl_person_p_00000;
-- COPY only the payload column; partition_id picks up the leaf DEFAULT.
\copy raw.pdl_person_p_00000 (payload) FROM '${UNCOMPRESSED}' WITH (FORMAT csv, DELIMITER E'\x01', QUOTE E'\x02');
COMMIT;
SELECT 'rows loaded: ' || COUNT(*) FROM raw.pdl_person;
SQL

rm -f "${UNCOMPRESSED}"

echo "==> fixture-load done"
