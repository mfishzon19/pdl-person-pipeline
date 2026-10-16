"""
DISCLAIMER — EXPLORATORY / R&D CONTEXT

Part of the cleansing R&D. See sibling *.sql files and the design target
(docs/design/21_cleansing_layer_design.md). In the pipeline this becomes a
subclass of the generic PDL caller in processing/pdl_api/.
================================================================================

Pull PDL company ids for companies in the normalized company hierarchy that
DIDN'T match via SQL name matching (tier: no_match). Uses PDL's
`/v5/company/clean` — name only, since the hierarchy input has no websites.

Sits on top of `cleansing_rad.company_hierarchy_pdl_match` — the two-tier SQL
match built by `company_hierarchy_pdl_match.sql`. For every row still marked
'no_match', call the Cleaner. On hit: record the returned pdl_company_id, flip
match_tier to 'cleaner_api', and backfill company_id + matched_name from
integration.company (a Cleaner hit may resolve to a pdl_id we don't hold
locally, in which case company_id stays null).

IMPLEMENTATION-STEP NOTE: rows that stay 'no_match' AFTER this script are
companies PDL doesn't hold at all (defunct, very small, corrupted names).
Implementation must CREATE these in integration.company with
pdl_company_id = null and then wire the corresponding parent/child edges
into integration.company_affiliation. See the "IMPLEMENTATION STEP"
section in company_hierarchy_pdl_match.sql.

This script calls the real PDL API and consumes credits, so it is a dry run
unless --execute is passed. The API key is read from the PDL_API_KEY
environment variable only. Never run it from tests.

Prerequisites (env vars):
    DATABASE_URL   — e.g. postgresql://pdl_etl:pdl_etl_dev@localhost:5432/pdl_etl
    PDL_API_KEY    — your PDL API key

Usage:
    python company_hierarchy_pdl_cleaner.py                          # dry run (default): list what would be called
    python company_hierarchy_pdl_cleaner.py --execute                # call PDL for all no_match companies
    python company_hierarchy_pdl_cleaner.py --execute --refresh-all  # re-call for every row
    python company_hierarchy_pdl_cleaner.py --execute --rpm 30
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

import psycopg2
import requests

PDL_ENDPOINT = "https://api.peopledatalabs.com/v5/company/clean"
DEFAULT_RPM  = 60


ADD_COLUMN_SQL = """
    alter table cleansing_rad.company_hierarchy_pdl_match
      add column if not exists pdl_lookup_status   smallint,
      add column if not exists pdl_lookup_response jsonb,
      add column if not exists pdl_lookup_at       timestamptz;
"""


SELECT_COMPANIES_SQL = """
    select source_name
      from cleansing_rad.company_hierarchy_pdl_match
     where (%(refresh_all)s or match_tier = 'no_match')
       and length(source_name) > 0
     order by source_name;
"""


UPDATE_COMPANY_SQL = """
    update cleansing_rad.company_hierarchy_pdl_match
       set pdl_company_id      = coalesce(%(pdl_id)s, pdl_company_id),
           match_tier          = case
                                   when %(pdl_id)s is not null then 'cleaner_api'
                                   else match_tier
                                 end,
           pdl_lookup_status   = %(status)s,
           pdl_lookup_response = %(response)s,
           pdl_lookup_at       = now()
     where source_name = %(source_name)s;
"""


BACKFILL_COMPANY_SQL = """
    update cleansing_rad.company_hierarchy_pdl_match m
       set company_id   = c.id,
           matched_name = c.name
      from integration.company c
     where m.pdl_company_id = c.pdl_company_id
       and m.match_tier     = 'cleaner_api'
       and m.company_id     is null;
"""


def sanity(conn):
    with conn.cursor() as cur:
        cur.execute("select current_database(), inet_server_addr(), current_user")
        db, addr, usr = cur.fetchone()
    print(f"connected: db={db!r} host={addr} user={usr!r}")
    if db != "pdl_etl":
        print(f"WARN: expected db='pdl_etl'; got {db!r}", file=sys.stderr)
    if usr != "pdl_etl":
        print(f"WARN: expected user='pdl_etl'; got {usr!r}", file=sys.stderr)


def call_cleaner(name, api_key, timeout=30):
    r = requests.get(PDL_ENDPOINT,
                     headers={"X-Api-Key": api_key},
                     params={"name": name},
                     timeout=timeout)
    try:
        body = r.json()
    except ValueError:
        body = {"raw_body": r.text}
    return r.status_code, body


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--refresh-all", action="store_true",
                   help="re-call PDL for every row, not just no_match ones")
    p.add_argument("--execute", action="store_true",
                   help="actually call the PDL API and write results "
                        "(default is a dry run: no API calls, no writes)")
    p.add_argument("--rpm", type=int, default=DEFAULT_RPM,
                   help=f"PDL requests per minute (default {DEFAULT_RPM})")
    args = p.parse_args()
    args.dry_run = not args.execute

    try:
        db_url = os.environ["DATABASE_URL"]
    except KeyError:
        sys.exit("ERROR: DATABASE_URL not set.")
    try:
        api_key = os.environ["PDL_API_KEY"]
    except KeyError:
        if not args.dry_run:
            sys.exit("ERROR: PDL_API_KEY not set.")
        api_key = "DRY_RUN"

    conn = psycopg2.connect(db_url)
    conn.autocommit = True
    sanity(conn)

    if not args.dry_run:
        with conn.cursor() as cur:
            cur.execute(ADD_COLUMN_SQL)
        print("ensured pdl_lookup_* audit columns exist")

    with conn.cursor() as cur:
        cur.execute(SELECT_COMPANIES_SQL, {"refresh_all": args.refresh_all})
        names = [r[0] for r in cur.fetchall()]

    print(f"companies to process: {len(names)}"
          f"{' (refresh_all)' if args.refresh_all else ' (no_match only)'}"
          f"{' [DRY RUN]' if args.dry_run else ''}\n")

    if args.dry_run:
        for name in names[:20]:
            print(f"  {name}")
        if len(names) > 20:
            print(f"  ... {len(names) - 20} more")
        return

    min_interval = 60.0 / args.rpm if args.rpm else 0.0
    last_call = 0.0
    n_hit, n_none, n_err = 0, 0, 0

    for i, name in enumerate(names, 1):
        if min_interval:
            wait = min_interval - (time.monotonic() - last_call)
            if wait > 0:
                time.sleep(wait)
            last_call = time.monotonic()

        status, body = call_cleaner(name, api_key)
        pdl_id = body.get("id") if status == 200 and isinstance(body, dict) else None

        if pdl_id:
            outcome = pdl_id
            n_hit += 1
        elif status in (200, 404):
            outcome = "no_match"
            n_none += 1
        else:
            outcome = f"HTTP {status}"
            n_err += 1

        with conn.cursor() as cur:
            cur.execute(UPDATE_COMPANY_SQL, {
                "pdl_id":       pdl_id,
                "status":       status,
                "response":     json.dumps(body),
                "source_name":  name,
            })

        # Progress ping every 100 companies
        if i % 100 == 0 or i == len(names):
            print(f"  [{i:5}/{len(names)}] hit={n_hit} miss={n_none} err={n_err}  last: {name[:60]} -> {outcome}")

    print(f"\ncleaner run summary: hit={n_hit}  no_match={n_none}  error={n_err}  (total={len(names)})")

    # Backfill company_id + matched_name for the Cleaner hits that also
    # exist in integration.company.
    with conn.cursor() as cur:
        cur.execute(BACKFILL_COMPANY_SQL)
        landed_locally = cur.rowcount
    print(f"backfilled company_id + matched_name for {landed_locally} rows (pdl_id resolved in integration.company)")

    conn.close()


if __name__ == "__main__":
    main()
