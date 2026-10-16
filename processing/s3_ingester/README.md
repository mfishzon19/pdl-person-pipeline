# processing/s3_ingester/

Pipeline step 1: config-driven ingestion of PDL Person deliveries from S3 (or local MinIO) into `raw.*`, with the identity-ledger projection of PDL's delta files. Design: [`docs/design/02_pipeline_design.md`](../../docs/design/02_pipeline_design.md) Section 6 (ingester) and Section 10 (catalog logging).

## Architecture: Finder → Loader → per-file primitive → PDL projection

- **`finder.py`** — per delivery, source-aware. Checks the `COMPLETED` sentinel, lists S3 for a `(source, delivery_date)` per the YAML's `file_groups`, and in one transaction writes a `catalog.pipeline_run` + `catalog.ingestion_run` row, one `pending` `catalog.ingestion_file` row per matched key, and (PDL) the `catalog.pdl_delivery` row. Finder never writes to S3.
- **`delivery_loader.py`** — per delivery, source-agnostic. Reads the run's pending `ingestion_file` rows, applies the config's `replace_strategy` (`full` truncates each parent target first), loops the files (sequentially or on a small thread pool, `--max-concurrency`), calls the per-file primitive for each, and finalizes `ingestion_run` with totals.
- **`file_ingester.py`** — per-file primitive `ingest_file(...)`. Manages the `ingestion_file` status lifecycle (`loading` → `success` / `failed`), creates the partition leaf on demand, downloads the object with boto3, gunzips it, and loads it with TRUNCATE + psycopg2 `COPY ... FROM STDIN`. Same shape for partitioned and flat tables.
- **`pdl_projection_runner.py`** — runs `SELECT raw.project_pdl_deltas(:delivery_date)`, which projects the merged / deleted / opted-out delta files into the `catalog` identity ledger (`pdl_id_aliases`, `pdl_inactive`, `merge_events`). The projection logic lives in the hand-authored repeatable migration `R__function_project_pdl_deltas.sql`, not in Python — Finder and Loader stay generic.
- **`run.py`** — chains Finder → Loader → projection for one delivery in one process, and finalizes `pdl_delivery`.

**Load path.** Python fetches each file's bytes from S3 / MinIO (boto3 honours `AWS_ENDPOINT_URL`), decompresses `.gz` by key suffix or `Content-Encoding`, and loads them into the leaf with `COPY ... FROM STDIN` on the same connection. No Postgres-side S3 extension is involved. Peak memory is bounded by the largest single decompressed file.

**Idempotency.** Re-running a delivery is safe: every file is TRUNCATE + COPY into its own leaf, `replace_strategy: full` clears the parents first, and the projection is `ON CONFLICT DO NOTHING` keyed on the delivery date. A re-run of `run.py` starts a new `ingestion_run`; running the Loader against an existing `ingestion_run_id` loads only files still `pending`.

## Layout

```
__init__.py
run.py                       one-delivery entry point: Finder → Loader → projection
finder.py                    scans S3, writes catalog rows
delivery_loader.py           loops pending ingestion_file rows, calls ingest_file per row
file_ingester.py             per-file primitive: three-transaction ingestion_file lifecycle + COPY
pdl_projection_runner.py     wraps SELECT raw.project_pdl_deltas(...)
configs/<source>.yaml        per-source YAML (Finder + Loader keys; see configs/README.md)
sources/                     placeholder package for source-specific helpers (empty; PDL uses the generic path)
tests/                       pytest suite + smoke_test_local.py (standalone script)
```

## Implementation walkthrough

Reading order: the architecture above, this section, then the module docstrings.

### Three-transaction status lifecycle (`file_ingester.py`)

`ingest_file()` writes three discrete transactions per file. Each commit boundary is a state visible to outside observers (other catalog readers, monitoring queries):

| | What it commits | Why a separate tx |
|---|---|---|
| **tx1** | `UPDATE catalog.ingestion_file SET status='loading', load_started_at=now()` | Commits immediately so observers see "this file is in flight" without waiting for the load. |
| **tx2** | All the work atomically: `CREATE TABLE IF NOT EXISTS leaf` (partitioned mode), `ALTER TABLE leaf ALTER COLUMN <col> SET DEFAULT <value>`, TRUNCATE + `COPY ... FROM STDIN` + `COUNT(*)`, then `UPDATE ingestion_file SET status='success', row_count=…`. | Atomicity of "work + status update". Any error rolls back the whole transaction — no partial leaf data, no inconsistent status. |
| **tx3** | (Only if tx2 raised) Fresh transaction: `UPDATE ingestion_file SET status='failed', error_message=…`, then re-raise. | tx2's rollback also undid the `'loading'` UPDATE, so the failure needs its own transaction. |

Each transaction is a psycopg2 connection context (`with conn:` commits on exit, rolls back on exception); three sequential `with conn:` blocks give three commit boundaries from one call.

### Callback pattern (where `action` runs)

`ingest_file()` doesn't run the state machine itself — `_run_with_catalog_lifecycle(conn, file_id, load_action)` does:

```
delivery_loader.load_pending_files(...)  ─┐
                                          │ for each pending file:
                                          ↓
                file_ingester.ingest_file(...)
                  ├─ build pre_copy_ddl (CREATE leaf + ALTER SET DEFAULT, partitioned mode)
                  ├─ define `action(cur)` closure that:
                  │     - executes pre_copy_ddl
                  │     - calls _copy_from_s3(...)  (download, gunzip, TRUNCATE, COPY, COUNT)
                  │     - returns the row counts
                  ├─ open psycopg2 connection
                  └─ call _run_with_catalog_lifecycle(conn, file_id, action)
                                                              ↓
                          _run_with_catalog_lifecycle:
                            - tx1: UPDATE → 'loading'
                            - tx2: counts = action(cur); UPDATE → 'success'
                            - on tx2 exception: tx3 UPDATE → 'failed'; raise
```

The lifecycle helper is a generic state machine; the closure carries all the context (table names, COPY options, pre-built DDL). Any future per-file operation that wants the same `loading → success / failed` lifecycle passes its own closure.

### Common failure modes

| Symptom | Cause |
|---|---|
| `RuntimeError: ingestion_run X has no pending ingestion_file rows` | The `ingestion_file` INSERTs were rolled back, or the Loader is pointed at a different `ingestion_run_id`. |
| Finder fails: sentinel not found | The delivery's `COMPLETED` object isn't there yet (or wrong `--delivery-date` / bucket). With MinIO, run `make dev-up-ingester` to seed the fixture. |
| `NoSuchBucket` / connection refused on `localhost:9000` | MinIO not running, or `AWS_ENDPOINT_URL` not set for a local run. |
| Partition overlap error creating a leaf | `raw.pdl_person` was pre-populated by `fixture-load`; use `make dev-up-ingester` (keeps raw empty) or `make dev-reset`. |
| `database files are incompatible with server` (Postgres startup) | Old volume from another Postgres major version. `make dev-reset`. |

## Running

From the repo root in the `pdl_test` conda env with the local stack up:

```bash
make dev-up-ingester    # postgres + flyway + MinIO seeded with the sanitized fixture, raw.* empty
make ingest-pdl         # run.py against MinIO (DELIVERY_DATE=yyyy_mm_dd to override)
```

Or call the modules directly (`set -a; source .env; set +a` first — see `.env.example`):

```bash
# End-to-end, one delivery
python -m processing.s3_ingester.run \
  --source pdl_full_local --delivery-date 2026_05_22 --max-concurrency 2

# Individual stages (debugging)
python -m processing.s3_ingester.finder \
  --source pdl_full_local --delivery-date 2026_05_22          # prints ingestion_run_id
python -m processing.s3_ingester.delivery_loader \
  --source pdl_full_local --ingestion-run-id <uuid> --max-concurrency 2
python -m processing.s3_ingester.pdl_projection_runner \
  --delivery-date 2026-05-22                                  # ISO date; idempotent per delivery
```

`run.py` / `finder.py` also accept an optional `--pipeline-version` (recorded on `catalog.pipeline_run`, default `local`); pin it to a git SHA or release tag when a run should be traceable to a code version.

To read a real PDL delivery bucket instead of MinIO: set the bucket in `configs/pdl_full.yaml`, unset `AWS_ENDPOINT_URL`, supply AWS credentials (or `AWS_PROFILE`) with read access, and use `--source pdl_full`.

## Adding a new source

1. Add `configs/<source>.yaml` (see [`configs/README.md`](configs/README.md)) and the raw tables in DBML + a Flyway migration.
2. If the source has post-load semantics (like PDL's deltas → ledger), author a hand-written `R__function_project_<source>.sql`; per-source helpers go under `sources/<source>/`.
3. No framework changes — Finder, Loader and the per-file primitive are config-driven.

## Tests

```bash
pytest processing/s3_ingester/tests/
```

S3 and PDL are mocked; integration tests skip unless `DATABASE_URL` points at a local Postgres (see [CLAUDE.md](../../CLAUDE.md)). [`tests/smoke_test_local.py`](tests/smoke_test_local.py) is a standalone end-to-end script (seeded mode needs only Postgres; finder mode needs MinIO) — its docstring lists prerequisites and expected output.
