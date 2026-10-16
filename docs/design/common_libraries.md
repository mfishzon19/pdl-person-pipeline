# Common Libraries — design

**Audience:** contributors writing code in `processing/`
**Scope:** the `processing.common.*` packages — the seam between pipeline code and external dependencies (Postgres driver, AWS SDK for S3 / MinIO, PDL HTTP client) plus shared delivery pre-flight checks and logging setup.

For a developer-facing quickstart (import names + minimal usage), see `processing/common/README.md`. This document captures *why* the seam exists, the error model, and per-module specifics.

## Why this layer exists

Without a shared layer, every Python module that talks to Postgres, S3 or PDL reinvents:

- DSN / region / endpoint resolution (which env var wins; what's the boto3 default).
- `with conn: with conn.cursor() as cur: ...` ceremony around every read.
- Transaction discipline (some files commit, some forget, some double-roll-back on error).
- Driver exception handling (some catch `psycopg2.errors.UniqueViolation`, some `psycopg2.IntegrityError`, some let raw driver exceptions leak).
- HTTP retry / backoff policy for PDL.

That drift produces bugs that look identical at the call site but behave differently under load (deadlocks not retried, unique violations swallowed, transactions left dangling on partial failure). `processing.common.*` centralizes the contract so a fix or upgrade lands in one place.

## Layout

```
processing/common/
├── README.md          # developer quickstart (imports + minimal usage)
├── logging_setup.py   # configure_logging() — stderr handler for every CLI entrypoint
├── db/                # psycopg2 wrappers — connection, execution, transactions, bulk insert
│   ├── __init__.py    # re-exports connect, execute, fetch_*, transaction, batch_insert, error types
│   ├── connect.py     # connect (DSN / DATABASE_URL / libpq fallthrough)
│   ├── errors.py      # DBOpsError hierarchy
│   ├── execute.py     # execute, fetch_one, fetch_all, fetch_dict_all
│   ├── transaction.py # transaction() context manager
│   ├── batch.py       # batch_insert (execute_values wrapper)
│   └── tests/
├── aws/               # boto3 wrappers — S3 + Secrets Manager
│   ├── __init__.py    # re-exports get_secret, list_keys, get_object_bytes, error types
│   ├── errors.py      # AWSOpsError hierarchy
│   ├── s3.py          # list_keys, get_object_bytes
│   ├── secrets.py     # get_secret
│   └── tests/
├── pdl/               # PDL HTTP client
│   ├── __init__.py
│   └── client.py      # pdl_api_call, call_pdl_with_retry
└── preflight/         # delivery readiness checks against an S3 / MinIO prefix
    ├── __init__.py
    ├── checks.py      # check_completed_sentinel, list_partition_ids, verify_*_encoding
    └── tests/
```

## Shared principles

Three rules every `common.*` module follows:

### 1. Single seam — driver imports stay inside `common`

New code under `processing/` should import from `processing.common.*`, not from `psycopg2` / `boto3` / `botocore` / `requests` directly. Not enforced by tooling; reviewers catch it.

Known exceptions: `processing/s3_ingester/` (`finder.py`, `file_ingester.py`, `delivery_loader.py`) builds its own boto3 S3 client and uses raw psycopg2 for `COPY ... FROM STDIN`; `processing/pdl_api/base.py` and `company_enrichment.py` use `psycopg2.extras` (`RealDictCursor`, `execute_values`). These need driver features the wrappers don't expose yet; migrate them when the wrapper grows the feature.

### 2. Stable error hierarchy

Driver exceptions are caught at the boundary and re-raised as a small, stable set of types from `<module>.errors`. Callers `except` on intent (`NotFound`, `IntegrityError`, `TransientError`), not on driver-specific exception classes.

The original driver exception is chained via `__cause__`, so callers that genuinely need driver-level detail still have it.

### 3. Tests run without live infrastructure

Tests must run on a clean checkout with no database, no AWS credentials and no network. Tests under `processing/common/*/tests/` mock at the driver boundary (`unittest.mock.MagicMock`; no `moto`). Live smoke tests, where they exist, are gated behind pytest markers (e.g. `pytest -m pdl_smoke`) and never run by default.

### Dependency flow

One-way: consumers import `common`; `common` never imports from `s3_ingester/`, `pdl_api/`, or anywhere else in `processing/`.

---

## `processing.common.db`

The place pipeline code talks to Postgres.

### Public API

| Name | Purpose |
|---|---|
| `connect(dsn=None)` | Open a connection. Resolution order: explicit DSN, then `DATABASE_URL`, then libpq defaults (`PGHOST` / `PGPORT` / `PGUSER` / `PGPASSWORD` / `PGDATABASE`). Mirrors the Flyway config flow, so the local Docker Postgres (`postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl`) works with no code changes. |
| `execute(conn, sql, params)` | Run INSERT / UPDATE / DELETE / DDL. Returns `rowcount`. |
| `fetch_one(conn, sql, params)` | Run SELECT, return the first row as a tuple (or `None`). |
| `fetch_all(conn, sql, params)` | Run SELECT, return all rows as a list of tuples. |
| `fetch_dict_all(conn, sql, params)` | Run SELECT, return list of dicts keyed by column name. |
| `transaction(conn)` | Context manager. BEGIN → block → COMMIT on success, ROLLBACK on any exception. |
| `batch_insert(conn, *, table, columns, rows, page_size, on_conflict)` | Bulk INSERT via `execute_values`. Faster than `executemany` for >100 rows. |

### Error model

```
DBOpsError
  ├── ConnectionFailed       opening / lost connection
  ├── QueryError             SQL execution failed
  │     └── IntegrityError   UNIQUE / FK / NOT NULL / CHECK
  └── TransientError         serialization / deadlock / lock timeout (retry-worthy)
```

### Transaction discipline

Two patterns, both correct:

```python
# Pattern A — explicit transaction block.
conn = connect()
try:
    with transaction(conn):
        execute(conn, "INSERT INTO foo VALUES (%s)", (1,))
        execute(conn, "INSERT INTO bar VALUES (%s)", (2,))
    # Either both commit, or both roll back.
finally:
    conn.close()

# Pattern B — read-only, no enclosing transaction.
conn = connect()
try:
    row = fetch_one(conn, "SELECT now()")
finally:
    conn.close()
```

`transaction()` does NOT nest. `psycopg2` lacks native nested transactions; if a SAVEPOINT is genuinely needed, issue it at the call site and document why.

`execute()` and the `fetch_*` family never commit on their own. They run inside whatever transaction state the caller has set up, matching `psycopg2`'s default behavior.

### What's NOT in the public API

- **Connection pooling.** Each `connect()` returns a fresh connection; each CLI run is one process with one connection lifetime. Adding `psycopg2.pool` here would be premature.
- **ORM-style mapping.** No model classes, no automatic case conversion, no migrations. The SQL is the contract; this module is plumbing.
- **Reflection / schema introspection.** DBML (`modeling/dbml/`) is the schema source of truth. Callers that need column lists should derive them from DBML, not query `information_schema`.
- **`COPY ... FROM STDIN`.** The raw loader (`processing/s3_ingester/file_ingester.py`) uses psycopg2's `copy_expert` directly. If a second caller needs COPY, add a `copy_from_stream` wrapper here.

### Migrating a caller

Before:

```python
import psycopg2
conn = psycopg2.connect(os.environ["DATABASE_URL"])
try:
    with conn:
        with conn.cursor() as cur:
            cur.execute("SELECT foo FROM bar WHERE id = %s", (id,))
            (foo,) = cur.fetchone()
finally:
    conn.close()
```

After:

```python
from processing.common.db import connect, fetch_one

conn = connect()
try:
    (foo,) = fetch_one(conn, "SELECT foo FROM bar WHERE id = %s", (id,))
finally:
    conn.close()
```

Wrap writes in `transaction(conn)`.

### Open questions

- Retry on `TransientError`. Callers handle retries today; centralizing needs a backoff policy decision.
- `psycopg2.sql.Identifier` for safe runtime-built identifiers. Currently used at the call site in `file_ingester.py`; not re-exported here. If the pattern spreads, expose it.

---

## `processing.common.aws`

The place pipeline code talks to S3 (real AWS S3 for PDL deliveries, or local MinIO) and, optionally, Secrets Manager.

### Public API

| Name | Service | Purpose |
|---|---|---|
| `list_keys(bucket, prefix, region)` | S3 | Yield every object key under `bucket/prefix`. Paginated under the hood. |
| `get_object_bytes(bucket, key, region)` | S3 | Download a small object as bytes. Not for delivery-file-sized objects — the raw loader streams those. |
| `get_secret(name, field=None, region=None, parse_json=True)` | Secrets Manager | Fetch a secret; returns the requested JSON field, or the raw string for non-JSON secrets. Optional — the default local setup reads secrets from env vars / `.env` (`DATABASE_URL`, `PDL_API_KEY`). |

### Error model

```
AWSOpsError
  ├── NotFound          NoSuchKey / NoSuchBucket / ResourceNotFoundException
  ├── AccessDenied      AccessDenied / 403 / AllAccessDisabled
  └── TransientError    Throttling / SlowDown / 5xx / RequestTimeout (retry-worthy)
```

Other `ClientError` codes fall through as the base `AWSOpsError`. The original exception is preserved via `__cause__`. (The S3 helpers translate errors; `get_secret` currently lets boto3 errors through and raises `ValueError` / `KeyError` for a missing JSON field.)

Callers should:

- Catch `NotFound` to handle missing objects.
- Catch `AccessDenied` and surface a clear error (almost always a credentials / profile problem).
- Catch `TransientError` and retry with backoff if the work is idempotent.
- Catch `AWSOpsError` as the defensive default.

### Credentials and endpoint override (MinIO)

Credentials come from the standard AWS credential chain — set `AWS_PROFILE` (or the usual `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) to read real PDL deliveries from S3.

For local MinIO, `boto3` honors the `AWS_ENDPOINT_URL` env var. The Makefile ingester targets export `AWS_ENDPOINT_URL=http://localhost:9000` (plus the MinIO credentials) for the host-side ingester run. The `_client()` helper just calls `boto3.client(...)`, so the same code reads from MinIO or S3 with no code-path divergence. See [`local-dev-design.md`](local-dev-design.md).

### What's NOT in the public API

- **General-purpose boto3 fallback.** If you need a service this module doesn't expose, add a submodule with the same error-translation pattern rather than importing `boto3` at the call site.
- **Resource-level abstractions** (`boto3.resource('s3').Bucket(...)`). The client API is used throughout for consistency.
- **Multipart upload, presigned URLs, streaming downloads.** Add when a caller needs them.

### Migrating a caller

```python
# Before
import boto3
s3 = boto3.client("s3", region_name=region)
body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()

# After
from processing.common.aws import get_object_bytes
body = get_object_bytes(bucket=bucket, key=key, region=region)
```

```python
# Before
paginator = boto3.client("s3").get_paginator("list_objects_v2")
keys = [o["Key"] for page in paginator.paginate(Bucket=b, Prefix=p) for o in page.get("Contents", [])]

# After
from processing.common.aws import list_keys
keys = list(list_keys(b, p))
```

### Open questions

- An `object_exists(bucket, key)` helper for `head_object`-style existence checks (inlined in `finder.py`) and a streaming-download helper — both needed before the S3 ingester can drop its direct boto3 client.
- Retry-with-backoff on `TransientError`. Callers handle retries today.

---

## `processing.common.pdl`

The place pipeline code talks to the PDL HTTP API (`https://api.peopledatalabs.com`). Endpoint-agnostic; workflow concerns (queues, audit, batching, credit caps) live in `processing/pdl_api/` ([`18_pdl_api_generic_caller.md`](18_pdl_api_generic_caller.md)).

| Name | Purpose |
|---|---|
| `pdl_api_call(endpoint, payload)` | One POST to `PDL_BASE + endpoint` with `X-Api-Key: $PDL_API_KEY`, 30 s timeout. Never raises on HTTP or transport failure; returns `{http_status, body, latency_ms, error_message, retry_after}` (`http_status = None` on a transport error). |
| `call_pdl_with_retry(endpoint, payload, *, max_retries=5, sleep_fn=time.sleep)` | Wraps `pdl_api_call` with bounded retries on 429 / 502 / 503 / 504 and transport errors. Honors a numeric `Retry-After` header; otherwise jittered exponential backoff. Every delay is clamped to `MAX_BACKOFF_SECONDS` (60). Non-retryable responses (2xx, 404, other 4xx) return on the first attempt; after `max_retries` the last result is returned so the caller can still audit the failure. |

Error model: none of its own — results are data, not exceptions, so callers (the `pdl_api` audit tables) can persist every outcome. `sleep_fn` is injectable so tests never wait on real backoff. All tests mock the HTTP call; the live smoke test (`processing/pdl_api/tests/test_pdl_smoke.py`) runs only with `pytest -m pdl_smoke` and `PDL_API_KEY` set.

Not implemented: an account-wide throttle across endpoints (rate pacing is per caller via `rate_limit_rpm` in `pdl_api`).

---

## `processing.common.preflight`

Delivery readiness checks against an S3 / MinIO prefix, designed for any S3-delivered source. Each function takes a boto3 S3 client as its first argument.

| Name | Purpose |
|---|---|
| `check_completed_sentinel(s3, bucket, prefix, *, sentinel_name="COMPLETED")` | `True` if the delivery's sentinel object exists at the delivery root (one level above the data folder: `2026_04_22/data/` → `2026_04_22/COMPLETED`). Returns `False` on 404 so the caller can wait; other S3 errors raise. |
| `list_partition_ids(s3, bucket, prefix, *, key_pattern=DEFAULT_PART_PATTERN)` | Sorted integer partition ids of files matching PDL's `part-NNNNN.csv.gz` (override `key_pattern` for other naming). |
| `verify_object_encoding(s3, bucket, key)` | Raise if the object lacks `Content-Encoding: gzip`. |
| `verify_content_encoding(s3, bucket, keys)` | `verify_object_encoding` over a list; stops at the first failure. |

The raw loader gunzips by key suffix (`.gz`) or header, so the encoding check is advisory for it; it matters for consumers that decompress based on the header alone. The S3 ingester's Finder does its own sentinel `head_object` check and does not call these helpers.

---

## `processing.common.logging_setup`

`configure_logging()` — called once, first thing, by every `s3_ingester` CLI entrypoint (run / finder / file_ingester / delivery_loader / projection runner); the `pdl_api` CLIs do not use it. Attaches one stderr handler to the `processing` package logger; stdout stays reserved for program output (summary JSON, ids) so it can be piped. Idempotent. `LOG_LEVEL` overrides the default `INFO`.

---

## When to add a new `common` module

Add a new submodule under `processing/common/` when:

1. **Multiple callers in `processing/` import the same third-party driver** and end up duplicating connection / config / error-handling logic.
2. **The seam matters operationally** — driver upgrades or retry-policy changes need a single place to land.
3. **You can write the error hierarchy first.** If the error model isn't clear yet, the abstraction is premature; let the call-site logic stabilize, then extract.

Don't add a `common` module just because a library is shared across two callers — that's what `import` is for. Add one when the call sites are accidentally diverging on contract. And don't add `common/utils.py` — push the function into a typed concern.
