#!/usr/bin/env python3
"""sanitize-pdl-fixture.py — generate a sanitized PDL fixture from a real delivery.

Streams JSONL from a real PDL part file in your PDL delivery bucket,
replaces every PII field with faker-generated values, preserves all shape
variations + nesting + list lengths + value-presence distributions, and
emits a gzipped JSONL ready to be hosted at FIXTURE_URL or dropped into
infra/local/fixtures-cache/.

Why this exists: dbt model development needs raw.pdl_person populated with
data shaped like production so JSON_TABLE NESTED PATH unnest etc. exercise
real edge cases. Real PDL responses contain real PII; this script produces
a 1:1-shaped but identity-free version safe to host publicly.

What gets faker'd:
  Person identity:      full_name, first_name, middle_name, last_name,
                        middle_initial, last_initial
  Contact:              emails[], personal_emails, work_email,
                        recommended_personal_email, mobile_phone,
                        phone_numbers, street_addresses,
                        location_street_address, location_postal_code
  Social URLs:          linkedin_url, linkedin_id, linkedin_username,
                        facebook_*, twitter_*, github_*, profiles[]
  Demographics:         birth_date, birth_year, sex
  Free text:            headline, summary (replaced w/ faker.text similar len)
  Per-experience:       company.name + social-URL keys + summary
  Per-education:        school.name (any nested `name` key is replaced)
  Identifiers:          id (PDL pdl_id), operation_id, job_company_id,
                        job_company_linkedin_id

What's kept (preserves data shape for testing):
  - All list lengths, nesting structure, value presence (true/false/null distribution)
  - industry, job_title, job_title_levels, job_title_role, etc.
  - Geographic fields at country/region/locality level
  - Dates (job_start_date, job_last_changed, etc.) — schedule analytics testing
  - Company size + founded year (industry-distribution preserved)
  - Skills, interests (generic terms, no PII)
  - dataset_version, all enum-like fields

Usage:
  python3 sanitize-pdl-fixture.py \\
    --source-bucket pdl-ingest-prod \\
    --source-key yyyy_mm_dd/data/part-00000.csv.gz \\
    --rows 5000 \\
    --output /tmp/pdl-person-sample-v1.csv.gz \\
    --seed 42

The output is gzipped JSONL (one PDL-shaped JSON per line). The local
fixture-load.sh consumes this directly via psql \\copy.

Requires: boto3 (in environment.yml) and faker (`pip install faker`).
Uses the default boto3 credential chain (env vars / AWS_PROFILE).
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import random
import sys
import uuid
from dataclasses import dataclass
from typing import Any

import boto3
from faker import Faker

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class Args:
    source_bucket: str
    source_key: str
    rows: int
    output: str
    seed: int


def parse_args() -> Args:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--source-bucket", required=True)
    p.add_argument("--source-key", required=True, help="e.g. yyyy_mm_dd/data/part-00000.csv.gz")
    p.add_argument("--rows", type=int, default=5000)
    p.add_argument("--output", required=True)
    p.add_argument("--seed", type=int, default=42, help="faker seed for deterministic output")
    return Args(**vars(p.parse_args()))


# ─────────────────────────────────────────────────────────────────────────────
# Faker helpers
# ─────────────────────────────────────────────────────────────────────────────

# Sets of keys to redact at every level. Lowercased keys; matched exactly.
# Person names, usernames and social URLs are handled key-by-key in
# _sanitize_value so they stay consistent with one PersonContext.
EMAIL_KEYS = {"work_email", "recommended_personal_email"}
EMAIL_LIST_KEYS = {"emails", "personal_emails"}
PHONE_KEYS = {"mobile_phone"}
PHONE_LIST_KEYS = {"phone_numbers"}
ID_KEYS = {
    "id", "linkedin_id", "facebook_id", "job_company_id",
    "job_company_linkedin_id", "operation_id",
}
ADDRESS_KEYS = {
    "street_addresses", "location_street_address",
    "location_address_line_2", "location_postal_code",
    "job_company_location_street_address",
    "job_company_location_address_line_2",
    "job_company_location_postal_code",
}
FREE_TEXT_KEYS = {"summary", "headline"}
DEMOGRAPHIC_KEYS = {"birth_date", "birth_year", "sex"}
# `name` is matched at any depth, so experience[].company.name and
# education[].school.name are both replaced with a fake company name.
COMPANY_NAME_KEYS = {"job_company_name", "name"}


@dataclass
class PersonContext:
    """Carries the chosen fake identity across one record's nested structures
    so e.g. emails match the fake name, linkedin_url contains the username, etc."""
    first_name: str
    middle_name: str | None
    last_name: str
    full_name: str
    linkedin_username: str
    facebook_username: str
    twitter_username: str
    github_username: str

    @classmethod
    def fresh(cls, fake: Faker) -> PersonContext:
        first = fake.first_name()
        middle = fake.first_name() if fake.boolean(chance_of_getting_true=20) else None
        last = fake.last_name()
        full = f"{first} {last}" if not middle else f"{first} {middle} {last}"
        # Lowercased + numeric handle pattern PDL emits
        suffix = fake.lexify("?" * 6, letters="abcdef0123456789")
        username_root = (
            f"{first.lower()}-{last.lower()}-{fake.random_int(min=10, max=99)}{suffix}"
        )
        return cls(
            first_name=first,
            middle_name=middle,
            last_name=last,
            full_name=full,
            linkedin_username=username_root,
            facebook_username=f"{first.lower()}.{last.lower()}.{fake.random_int(min=1, max=9999)}",
            twitter_username=f"{first.lower()}_{last.lower()}{fake.random_int(min=10, max=99)}",
            github_username=f"{first.lower()}{last.lower()}{fake.random_int(min=1, max=999)}",
        )


def _fake_email(fake: Faker, name_seed: str) -> str:
    """Use the chosen fake name in the email local-part for realism."""
    return f"{name_seed}{fake.random_int(min=0, max=99)}@{fake.free_email_domain()}"


def _fake_phone(fake: Faker) -> str:
    return fake.numerify("##########")  # 10-digit, no formatting (PDL convention)


def _coerce_summary(orig: str | None, fake: Faker) -> str | None:
    if orig is None or not isinstance(orig, str):
        return orig
    target_len = max(20, len(orig))
    text = fake.text(max_nb_chars=target_len)
    return text[:target_len].rstrip()


# ─────────────────────────────────────────────────────────────────────────────
# Record-level sanitizer
# ─────────────────────────────────────────────────────────────────────────────

def sanitize_record(record: dict[str, Any], fake: Faker) -> dict[str, Any]:
    """Return a new dict with PII fields replaced. Preserves shape:
    None stays None, [] stays [], non-empty lists keep their length,
    nested objects retain all keys."""

    ctx = PersonContext.fresh(fake)
    out: dict[str, Any] = {}

    for key, val in record.items():
        out[key] = _sanitize_value(key, val, ctx, fake)

    return out


def _sanitize_value(key: str, val: Any, ctx: PersonContext, fake: Faker) -> Any:
    """Single-key sanitization. Recurses for lists/dicts."""
    # Preserve null/missing-as-bool (PDL emits `false` to mean "field absent" for some keys).
    if val is None or val is False:
        return val

    # Names
    if key == "full_name":
        return ctx.full_name
    if key == "first_name":
        return ctx.first_name
    if key == "middle_name":
        return ctx.middle_name
    if key == "last_name":
        return ctx.last_name
    if key == "middle_initial":
        return ctx.middle_name[0] if ctx.middle_name else None
    if key == "last_initial":
        return ctx.last_name[0]

    # Demographics — drop
    if key in DEMOGRAPHIC_KEYS:
        return None

    # IDs
    if key == "id":
        return f"fake-pdl-{uuid.uuid4().hex[:16]}"
    if key == "operation_id":
        return uuid.uuid4().hex + uuid.uuid4().hex[:32]  # 64 hex chars to match PDL shape
    if key == "linkedin_id":
        return str(fake.random_int(min=10000000, max=99999999))
    if key == "facebook_id":
        return str(fake.random_int(min=10**14, max=10**15 - 1))
    if key in ID_KEYS:
        return uuid.uuid4().hex[:28]

    # Usernames
    if key == "linkedin_username":
        return ctx.linkedin_username
    if key == "facebook_username":
        return ctx.facebook_username
    if key == "twitter_username":
        return ctx.twitter_username
    if key == "github_username":
        return ctx.github_username

    # Social URLs — keep host, randomize path
    if key == "linkedin_url":
        return f"linkedin.com/in/{ctx.linkedin_username}"
    if key == "facebook_url":
        return f"facebook.com/{ctx.facebook_username}"
    if key == "twitter_url":
        return f"twitter.com/{ctx.twitter_username}"
    if key == "github_url":
        return f"github.com/{ctx.github_username}"
    if key == "job_company_linkedin_url":
        return f"linkedin.com/company/{fake.slug()}"
    if key == "job_company_facebook_url":
        return f"facebook.com/{fake.slug()}"
    if key == "job_company_twitter_url":
        return f"twitter.com/{fake.slug()}"
    if key == "job_company_website":
        return fake.domain_name()

    # Emails
    if key in EMAIL_KEYS:
        return _fake_email(fake, ctx.first_name.lower() + "." + ctx.last_name.lower())
    if key in EMAIL_LIST_KEYS:
        if not isinstance(val, list):
            return val
        local_part = f"{ctx.first_name.lower()}.{ctx.last_name.lower()}"
        return [
            {"address": _fake_email(fake, f"{local_part}{i}"),
             "type": item.get("type") if isinstance(item, dict) else None}
            for i, item in enumerate(val)
        ]

    # Phones
    if key in PHONE_KEYS:
        return _fake_phone(fake)
    if key in PHONE_LIST_KEYS:
        if not isinstance(val, list):
            return val
        return [_fake_phone(fake) for _ in val]

    # Addresses
    if key in ADDRESS_KEYS:
        if isinstance(val, list):
            return [fake.street_address() for _ in val]
        return fake.street_address()

    # Free-text bios — replace, preserve length
    if key in FREE_TEXT_KEYS:
        return _coerce_summary(val, fake)

    # Company name (top-level + nested)
    if key in COMPANY_NAME_KEYS and isinstance(val, str):
        return fake.company()

    # `profiles` — list of social-account objects; each has network/id/url/username
    if key == "profiles" and isinstance(val, list):
        return [_sanitize_profile(item, ctx, fake) for item in val]

    # Lists: recurse element-wise
    if isinstance(val, list):
        return [_sanitize_value(key, item, ctx, fake) for item in val]

    # Dicts: recurse key-by-key
    if isinstance(val, dict):
        return {k: _sanitize_value(k, v, ctx, fake) for k, v in val.items()}

    # Everything else (preserved): primitive scalars (industry, job_title,
    # location_country, dates, booleans, numbers) — these are not PII.
    return val


def _sanitize_profile(item: Any, ctx: PersonContext, fake: Faker) -> Any:
    if not isinstance(item, dict):
        return item
    network = item.get("network")
    new = dict(item)
    if network == "linkedin":
        new["url"] = f"linkedin.com/in/{ctx.linkedin_username}"
        new["username"] = ctx.linkedin_username
        new["id"] = str(fake.random_int(min=10000000, max=99999999))
    elif network == "facebook":
        new["url"] = f"facebook.com/{ctx.facebook_username}"
        new["username"] = ctx.facebook_username
        new["id"] = str(fake.random_int(min=10**14, max=10**15 - 1))
    elif network == "twitter":
        new["url"] = f"twitter.com/{ctx.twitter_username}"
        new["username"] = ctx.twitter_username
    elif network == "github":
        new["url"] = f"github.com/{ctx.github_username}"
        new["username"] = ctx.github_username
    else:
        new["url"] = fake.url()
        new["username"] = fake.user_name()
    return new


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────


def main() -> int:
    args = parse_args()

    Faker.seed(args.seed)
    random.seed(args.seed)
    fake = Faker("en_US")

    s3 = boto3.client("s3")

    print(f"==> reading s3://{args.source_bucket}/{args.source_key}", file=sys.stderr)
    resp = s3.get_object(Bucket=args.source_bucket, Key=args.source_key)
    body = resp["Body"]

    # Stream-decompress + stream-write to keep memory bounded.
    out_path = args.output
    print(f"==> writing {out_path} (target rows: {args.rows})", file=sys.stderr)

    written = 0
    skipped_parse = 0

    with gzip.GzipFile(fileobj=body, mode="rb") as gz_in, \
         gzip.open(out_path, mode="wt", encoding="utf-8") as gz_out:

        for raw_line in gz_in:
            if written >= args.rows:
                break
            line = raw_line.decode("utf-8").rstrip("\n")
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                skipped_parse += 1
                continue

            sanitized = sanitize_record(record, fake)
            gz_out.write(json.dumps(sanitized, separators=(",", ":")))
            gz_out.write("\n")
            written += 1

            if written % 500 == 0:
                print(f"    {written}/{args.rows} sanitized", file=sys.stderr)

    print(f"==> done. wrote {written} rows ({skipped_parse} malformed lines skipped)",
          file=sys.stderr)
    print(f"==> output: {out_path}", file=sys.stderr)

    size_bytes = os.path.getsize(out_path)
    print(f"==> size: {size_bytes / 1024 / 1024:.2f} MB gzipped", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
