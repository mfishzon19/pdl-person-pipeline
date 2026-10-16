# processing/common/

Cross-cutting helpers shared across processing-layer code (`s3_ingester`, `pdl_api`). Design: [`docs/design/common_libraries.md`](../../docs/design/common_libraries.md).

## Subpackages

- `db/` — Postgres connection management, transaction wrapper, query / batch helpers, error hierarchy.
- `aws/` — boto3 wrappers for S3 and Secrets Manager with a stable error hierarchy. Optional: the default local setup reads secrets from env vars, and the ingester's Finder and file primitive call boto3 directly.
- `pdl/` — generic PDL API client primitives: `X-Api-Key` auth from `PDL_API_KEY`, HTTP call, retry with backoff on 429 / 5xx (honours `Retry-After`). Consumed by `pdl_api`. Workflow-level concerns (queues, batching, audit rows) live in `pdl_api`, not here.
- `preflight/` — standalone delivery readiness checks against an S3 prefix: `COMPLETED` sentinel present, partition file listing, object content-encoding check. (The ingester's Finder does its own sentinel check from the YAML config.)
- `logging_setup.py` — shared logging configuration for CLI entry points.

## Public API at a glance

```python
# Postgres
from processing.common.db import (
    connect,                                  # open a connection (DATABASE_URL)
    execute, fetch_one, fetch_all, fetch_dict_all,
    transaction,                              # context manager
    batch_insert,                             # bulk INSERT via execute_values
    DBOpsError, ConnectionFailed, QueryError, IntegrityError, TransientError,
)

# AWS
from processing.common.aws import (
    get_secret,                               # Secrets Manager (optional)
    list_keys, get_object_bytes,              # S3 (small artifacts)
    AWSOpsError, NotFound, AccessDenied, TransientError,
)

# PDL
from processing.common.pdl import pdl_api_call, call_pdl_with_retry

# Preflight
from processing.common.preflight import (
    check_completed_sentinel, list_partition_ids, verify_content_encoding,
)
```

## Dependency flow

One-way: consumers import `common`; `common` never imports from `s3_ingester/`, `pdl_api/`, or anywhere else in `processing/`. This keeps it cycle-free and reusable.

## Conventions

- Tests mock AWS, PDL and Postgres at the driver boundary (`unittest.mock`). No live AWS, PDL or DB calls per [CLAUDE.md](../../CLAUDE.md).
- Each subpackage stays focused on its named domain. No `common/utils.py` or `common/helpers.py` — put a function into a typed concern instead.
- Public API: anything re-exported from a subpackage's `__init__.py` is the stable contract. Callers don't import internal helper modules directly.
- Driver exceptions don't leak past the `db` / `aws` helpers: code that uses them catches the wrapped error types, not `psycopg2.errors` or `botocore.exceptions`.
