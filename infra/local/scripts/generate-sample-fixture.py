#!/usr/bin/env python3
"""generate-sample-fixture.py — build the committed, FULLY SYNTHETIC PDL sample.

Writes a gzipped JSONL file (one PDL-person-shaped JSON object per line,
the same format as a PDL delivery part file) that `make dev-up` loads into
raw.pdl_person when no FIXTURE_URL / cached fixture is configured.

Nothing in the output comes from PDL or any real dataset. Every person,
company and school is invented from small hard-coded word lists and a
seeded RNG; only public geography (city / region / country names) and
PDL's public taxonomy words (job roles, levels, industries, sizes) are
real. Domains use the reserved `.example` TLD; emails use example.com.

The record shape mirrors what the dbt staging models read (top-level
scalars, skills / interests / location_names / regions / countries,
experience[] with title + company + company.location, education[] with
school + school.location) and the PDL quirks they handle: bool-placeholder
strings ("true" / "false") on redacted top-level fields, yyyy / yyyy-mm /
yyyy-mm-dd dates, missing optional fields, duplicate person records,
duplicate experience / education entries and company-name variants.

Output is byte-for-byte deterministic for a given --seed / --persons.

Usage:
  python infra/local/scripts/generate-sample-fixture.py \\
      --output infra/local/fixtures/pdl-person-sample-v1.csv.gz
"""

from __future__ import annotations

import argparse
import gzip
import json
import random
import string
import sys
import unicodedata
from typing import Any

DATASET_VERSION = "31.2"
BASE62 = string.digits + string.ascii_letters

# ─────────────────────────────────────────────────────────────────────────────
# Vocabularies (all fictional except geography + PDL taxonomy words)
# ─────────────────────────────────────────────────────────────────────────────

FIRST_NAMES = [
    ("Alex", "male"),
    ("Jordan", None),
    ("Taylor", "female"),
    ("Morgan", "female"),
    ("Casey", "male"),
    ("Riley", "female"),
    ("Jamie", "male"),
    ("Avery", "female"),
    ("Quinn", None),
    ("Robin", "female"),
    ("Sam", "male"),
    ("Dana", "female"),
    ("Chris", "male"),
    ("Pat", None),
    ("Lee", "male"),
    ("Kim", "female"),
    ("Maria", "female"),
    ("Elena", "female"),
    ("Priya", "female"),
    ("Mei", "female"),
    ("Omar", "male"),
    ("Luca", "male"),
    ("Noah", "male"),
    ("Liam", "male"),
    ("Emma", "female"),
    ("Olivia", "female"),
    ("Sofia", "female"),
    ("Ana", "female"),
    ("Ravi", "male"),
    ("Kenji", "male"),
    ("Ingrid", "female"),
    ("Mateo", "male"),
    ("José", "male"),
    ("Zoë", "female"),
    ("Hannah", "female"),
    ("Daniel", "male"),
]
MIDDLE_NAMES = ["Lynn", "Marie", "James", "Ray", "Ann", "Lee", "Jo", "Kai"]
LAST_NAMES = [
    "Smith",
    "Johnson",
    "Brown",
    "Garcia",
    "Miller",
    "Davis",
    "Martinez",
    "Lopez",
    "Wilson",
    "Anderson",
    "Thomas",
    "Moore",
    "Jackson",
    "Martin",
    "White",
    "Harris",
    "Clark",
    "Lewis",
    "Walker",
    "Hall",
    "Young",
    "King",
    "Wright",
    "Hill",
    "Green",
    "Adams",
    "Baker",
    "Nelson",
    "Carter",
    "Patel",
    "Nguyen",
    "Kumar",
    "Müller",
    "Schmidt",
    "Rossi",
    "Dubois",
    "Silva",
    "Tanaka",
    "Novak",
    "O'Brien",
]

# (locality, region, country, continent, metro, geo, postal_code)
# Real public geography; metro only where PDL emits one (US).
CITIES = [
    (
        "san francisco",
        "california",
        "united states",
        "north america",
        "san francisco, california",
        "37.77,-122.41",
        "94105",
    ),
    (
        "oakland",
        "california",
        "united states",
        "north america",
        "san francisco, california",
        "37.80,-122.27",
        "94612",
    ),
    (
        "los angeles",
        "california",
        "united states",
        "north america",
        "los angeles, california",
        "34.05,-118.24",
        "90012",
    ),
    (
        "new york",
        "new york",
        "united states",
        "north america",
        "new york, new york",
        "40.71,-74.00",
        "10001",
    ),
    (
        "brooklyn",
        "new york",
        "united states",
        "north america",
        "new york, new york",
        "40.65,-73.94",
        "11201",
    ),
    ("austin", "texas", "united states", "north america", "austin, texas", "30.26,-97.74", "78701"),
    ("dallas", "texas", "united states", "north america", "dallas, texas", "32.77,-96.79", "75201"),
    (
        "seattle",
        "washington",
        "united states",
        "north america",
        "seattle, washington",
        "47.60,-122.33",
        "98101",
    ),
    (
        "chicago",
        "illinois",
        "united states",
        "north america",
        "chicago, illinois",
        "41.87,-87.62",
        "60601",
    ),
    (
        "boston",
        "massachusetts",
        "united states",
        "north america",
        "boston, massachusetts",
        "42.36,-71.05",
        "02108",
    ),
    (
        "denver",
        "colorado",
        "united states",
        "north america",
        "denver, colorado",
        "39.73,-104.99",
        "80202",
    ),
    (
        "atlanta",
        "georgia",
        "united states",
        "north america",
        "atlanta, georgia",
        "33.74,-84.38",
        "30303",
    ),
    ("toronto", "ontario", "canada", "north america", None, "43.65,-79.38", "M5H"),
    ("vancouver", "british columbia", "canada", "north america", None, "49.28,-123.12", "V6B"),
    ("london", "england", "united kingdom", "europe", None, "51.50,-0.12", "EC1A"),
    ("manchester", "england", "united kingdom", "europe", None, "53.48,-2.24", "M1"),
    ("berlin", "berlin", "germany", "europe", None, "52.52,13.40", "10115"),
    ("munich", "bavaria", "germany", "europe", None, "48.13,11.58", "80331"),
    ("paris", "île-de-france", "france", "europe", None, "48.85,2.35", "75001"),
    ("amsterdam", "north holland", "netherlands", "europe", None, "52.37,4.90", "1012"),
    ("bangalore", "karnataka", "india", "asia", None, "12.97,77.59", "560001"),
    ("singapore", "singapore", "singapore", "asia", None, "1.35,103.81", "018989"),
    ("sydney", "new south wales", "australia", "oceania", None, "-33.86,151.20", "2000"),
    ("são paulo", "são paulo", "brazil", "south america", None, "-23.55,-46.63", "01000"),
]

# PDL canonical-style industry values (shared by person + company, as in PDL).
INDUSTRIES = [
    ("computer software", "software development"),
    ("information technology and services", "it services and it consulting"),
    ("internet", "technology, information and internet"),
    ("financial services", "financial services"),
    ("banking", "banking"),
    ("insurance", "insurance"),
    ("hospital & health care", "hospitals and health care"),
    ("marketing and advertising", "advertising services"),
    ("management consulting", "business consulting and services"),
    ("retail", "retail"),
    ("logistics and supply chain", "transportation, logistics, supply chain and storage"),
    ("construction", "construction"),
    ("real estate", "real estate"),
    ("telecommunications", "telecommunications"),
    ("food & beverages", "food and beverage services"),
    ("higher education", "higher education"),
    ("renewables & environment", "renewable energy power generation"),
]

COMPANY_SIZES = [
    "1-10",
    "11-50",
    "51-200",
    "201-500",
    "501-1000",
    "1001-5000",
    "5001-10000",
    "10001+",
]

# Fictional companies: (name, slug, industry index, type, size index, founded)
COMPANIES = [
    ("Acme Corp", "acme", 3, "private", 6, 1948),
    ("Globex", "globex", 0, "public", 7, 1989),
    ("Initech", "initech", 1, "private", 4, 1995),
    ("Umbrella Group", "umbrella-group", 6, "public", 7, 1968),
    ("Hooli", "hooli", 2, "public", 7, 2003),
    ("Bluefin Analytics", "bluefin-analytics", 0, "private", 2, 2014),
    ("Cobalt Ridge Systems", "cobalt-ridge", 1, "private", 3, 2009),
    ("Pinecrest Logistics", "pinecrest-logistics", 10, "private", 5, 1987),
    ("Lumen Harbor Health", "lumen-harbor-health", 6, "nonprofit", 5, 1972),
    ("Quartzline Software", "quartzline", 0, "private", 1, 2019),
    ("Silverleaf Capital", "silverleaf-capital", 3, "private", 2, 2006),
    ("Tidewater Retail Group", "tidewater-retail", 9, "public", 7, 1961),
    ("Brightpath Learning", "brightpath-learning", 15, "private", 3, 2011),
    ("Ironbark Construction", "ironbark-construction", 11, "private", 4, 1979),
    ("Meadowlark Insurance", "meadowlark-insurance", 5, "public", 6, 1922),
    ("Copperbeam Consulting", "copperbeam", 8, "private", 4, 1998),
    ("Orchid Bay Hospitality", "orchid-bay", 14, "private", 3, 2001),
    ("Granite Peak Energy", "granite-peak-energy", 16, "private", 4, 2012),
    ("Harborview Realty", "harborview-realty", 12, "private", 2, 1993),
    ("Nimbus Telecom", "nimbus-telecom", 13, "public", 7, 1984),
    ("Falconet Robotics", "falconet-robotics", 0, "private", 2, 2017),
    ("Saffron Street Foods", "saffron-street", 14, "private", 3, 2008),
    ("Northgate Bank", "northgate-bank", 4, "public", 7, 1903),
    ("Vellum & Vine Media", "vellum-vine", 7, "private", 2, 2010),
    ("Tessellate Labs", "tessellate-labs", 2, "private", 1, 2021),
    ("Kestrel Freight", "kestrel-freight", 10, "private", 3, 1999),
]
# Name variants that PDL resolves to separate company entities (separate
# ids, near-identical names) — the "duplicate company name" case.
COMPANY_VARIANTS = [
    ("Acme Corporation", "acme-corporation", 0),  # variant of COMPANIES[0]
    ("acme corp.", "acme-corp-dot", 0),
    ("Globex Inc", "globex-inc", 1),
    ("Hooli Labs", "hooli-labs", 4),
]

# (title, role, sub_role, class, levels) — PDL canonical-style taxonomy values.
TITLES = [
    ("software engineer", "engineering", "software", "research_and_development", []),
    ("senior software engineer", "engineering", "software", "research_and_development", ["senior"]),
    ("staff software engineer", "engineering", "software", "research_and_development", ["senior"]),
    ("engineering manager", "engineering", "software", "research_and_development", ["manager"]),
    (
        "vice president of engineering",
        "engineering",
        "software",
        "research_and_development",
        ["vp"],
    ),
    ("devops engineer", "engineering", "devops", "research_and_development", []),
    ("data scientist", "research", "data_science", "research_and_development", []),
    ("data analyst", "analyst", "data_analyst", "general_and_administrative", []),
    (
        "software engineering intern",
        "engineering",
        "software",
        "research_and_development",
        ["training"],
    ),
    ("product manager", "product", "product_management", "research_and_development", ["manager"]),
    ("account executive", "sales", "account_executive", "sales_and_marketing", []),
    ("sales director", "sales", "account_management", "sales_and_marketing", ["director"]),
    ("customer success manager", "sales", "customer_success", "sales_and_marketing", ["manager"]),
    ("marketing manager", "marketing", "product_marketing", "sales_and_marketing", ["manager"]),
    ("content marketing specialist", "marketing", "content_marketing", "sales_and_marketing", []),
    ("recruiter", "human_resources", "recruiting", "general_and_administrative", []),
    (
        "director of human resources",
        "human_resources",
        "people",
        "general_and_administrative",
        ["director"],
    ),
    ("accountant", "finance", "accounting", "general_and_administrative", []),
    ("financial analyst", "finance", "investment", "general_and_administrative", []),
    ("chief financial officer", "finance", "accounting", "general_and_administrative", ["cxo"]),
    ("operations manager", "operations", "logistics", "general_and_administrative", ["manager"]),
    (
        "project manager",
        "operations",
        "project_management",
        "general_and_administrative",
        ["manager"],
    ),
    ("registered nurse", "health", "nursing", "services", []),
    ("teacher", "education", "teaching", "services", []),
    ("graphic designer", "creative", "graphic_design", "services", []),
    ("attorney", "legal", "lawyer", "services", []),
    ("management consultant", "professional_service", "consulting", "services", []),
    ("partner", "professional_service", "consulting", "services", ["partner"]),
    ("founder & ceo", None, None, None, ["owner", "cxo"]),  # PDL often leaves role NULL
    ("volunteer", None, None, None, ["unpaid"]),
]

SKILLS = [
    "python",
    "sql",
    "java",
    "javascript",
    "data analysis",
    "machine learning",
    "project management",
    "leadership",
    "negotiation",
    "customer service",
    "budgeting",
    "recruiting",
    "social media marketing",
    "accounting",
    "public speaking",
    "team building",
    "sales",
    "strategic planning",
    "research",
    "writing",
    "agile methodologies",
    "scrum",
    "linux",
    "cloud computing",
    "statistics",
    "financial analysis",
    "business development",
    "user experience design",
    "spreadsheets",
    "event planning",
]
INTERESTS = [
    "hiking",
    "photography",
    "cooking",
    "travel",
    "reading",
    "cycling",
    "chess",
    "music",
    "volunteering",
    "gardening",
    "running",
    "yoga",
    "painting",
    "board games",
    "fishing",
    "technology",
    "education",
    "health",
]

# Fictional schools: (name, slug, type, city index or None, coarse_only)
SCHOOLS = [
    ("Example State University", "examplestate", "post-secondary institution", 6, False),
    ("Northfield College", "northfield", "post-secondary institution", 9, False),
    ("Lakeshore Institute of Technology", "lakeshore-tech", "post-secondary institution", 8, False),
    ("Riverbend University", "riverbend", "post-secondary institution", 0, False),
    ("Pinecrest Community College", "pinecrest-cc", "post-secondary institution", 7, False),
    ("Westbrook School of Business", "westbrook-business", "post-secondary institution", 3, False),
    ("Eastmoor University", "eastmoor", "post-secondary institution", 14, False),
    ("Highcliff Polytechnic", "highcliff-poly", "post-secondary institution", 16, True),
    ("Cedar Valley University", "cedar-valley", "post-secondary institution", 10, False),
    ("Maple Hollow College", "maple-hollow", "post-secondary institution", 12, False),
    ("Fernhill University", "fernhill", "post-secondary institution", 20, True),
    ("Stonegate Technical Institute", "stonegate-tech", "post-secondary institution", 22, False),
    ("Willowmere University", "willowmere", "post-secondary institution", 19, True),
    ("Briarwood Secondary School", "briarwood-secondary", "secondary school", 11, False),
]
DEGREES = [
    (["bachelors", "bachelor of science"], ["computer science"]),
    (["bachelors", "bachelor of arts"], ["economics"]),
    (["bachelors", "bachelor of science"], ["mechanical engineering"]),
    (["bachelors", "bachelor of arts"], ["psychology"]),
    (["bachelors", "bachelor of business administration"], ["business administration"]),
    (["bachelors", "bachelor of science"], ["biology"]),
    (["bachelors", "bachelor of science"], ["accounting"]),
    (["masters", "master of business administration"], ["business administration"]),
    (["masters", "master of science"], ["computer science"]),
    (["masters", "master of science"], ["statistics"]),
    (["doctorates", "doctor of philosophy"], ["mathematics"]),
    (["associates", "associate of arts"], ["marketing"]),
    ([], []),
]
MINORS = ["mathematics", "english", "history", "music", "philosophy"]
SALARIES = [
    "<20,000",
    "20,000-25,000",
    "45,000-55,000",
    "55,000-70,000",
    "70,000-85,000",
    "85,000-100,000",
    "100,000-150,000",
    "150,000-250,000",
    ">250,000",
]
ONET = {
    "engineering": (
        "15-1252.00",
        "computer and mathematical occupations",
        "computer occupations",
        "software and web developers, programmers, and testers",
        "software developers",
    ),
    "sales": (
        "41-4012.00",
        "sales and related occupations",
        "sales representatives, wholesale and manufacturing",
        "sales representatives, wholesale and manufacturing",
        "sales representatives, wholesale and manufacturing, except technical products",
    ),
    "finance": (
        "13-2011.00",
        "business and financial operations occupations",
        "financial specialists",
        "accountants and auditors",
        "accountants and auditors",
    ),
}
SUMMARY_TEMPLATES = [
    "Experienced {title} focused on building reliable teams and processes.",
    "{title} with a background in {industry}.",
    "Passionate about {skill} and {skill2}.",
]


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────


def pdl_id(rng: random.Random) -> str:
    return "".join(rng.choice(BASE62) for _ in range(28))


def hexid(rng: random.Random, n: int) -> str:
    return "".join(rng.choice("0123456789abcdef") for _ in range(n))


def ascii_slug(text: str) -> str:
    folded = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return "".join(c for c in folded.lower() if c.isalnum())


def placeholder(rng: random.Random) -> str:
    """PDL redacts some top-level fields to the literal strings "true"/"false"."""
    return rng.choice(["true", "false"])


def fmt_date(rng: random.Random, year: int) -> str:
    """PDL ships dates as yyyy, yyyy-mm or yyyy-mm-dd (yyyy-mm most often)."""
    r = rng.random()
    if r < 0.2:
        return f"{year:04d}"
    if r < 0.9:
        return f"{year:04d}-{rng.randint(1, 12):02d}"
    return f"{year:04d}-{rng.randint(1, 12):02d}-{rng.randint(1, 28):02d}"


def city_name(c: tuple) -> str:
    return f"{c[0]}, {c[1]}, {c[2]}"


def location_obj(c: tuple, street: str | None, rng: random.Random) -> dict[str, Any]:
    return {
        "name": city_name(c),
        "locality": c[0],
        "region": c[1],
        "metro": c[4],
        "country": c[2],
        "continent": c[3],
        "street_address": street,
        "address_line_2": "suite " + str(rng.randint(100, 900))
        if street and rng.random() < 0.3
        else None,
        "postal_code": c[6] if street else None,
        "geo": c[5],
    }


# ─────────────────────────────────────────────────────────────────────────────
# Entity catalogs (built once, reused across persons)
# ─────────────────────────────────────────────────────────────────────────────


def build_companies(rng: random.Random) -> list[dict[str, Any]]:
    out = []
    specs = [(n, s, i, t, sz, f) for (n, s, i, t, sz, f) in COMPANIES]
    for name, slug, base in COMPANY_VARIANTS:
        _, _, i, t, sz, f = COMPANIES[base]
        specs.append((name, slug, i, t, sz, f))
    for idx, (name, slug, ind, ctype, size, founded) in enumerate(specs):
        hq = CITIES[rng.randrange(len(CITIES))]
        has_location = idx % 9 != 4  # a few companies with no HQ location
        street_word = rng.choice(["main", "market", "harbor", "park", "oak"])
        street = f"{rng.randint(1, 999)} {street_word} street"
        out.append(
            {
                "name": name.lower() if rng.random() < 0.5 else name,  # PDL lowercases most names
                "size": COMPANY_SIZES[size],
                "id": pdl_id(rng),
                "founded": founded if rng.random() < 0.85 else None,
                "industry": INDUSTRIES[ind][0],
                "industry_v2": INDUSTRIES[ind][1],
                "location": location_obj(hq, street if rng.random() < 0.6 else None, rng)
                if has_location
                else None,
                "linkedin_url": f"linkedin.com/company/{slug}-example",
                "linkedin_id": str(rng.randint(10_000, 99_999_999)),
                "facebook_url": f"facebook.com/{slug}-example" if rng.random() < 0.5 else None,
                "twitter_url": f"twitter.com/{slug.replace('-', '_')}_example"
                if rng.random() < 0.4
                else None,
                "website": f"{slug}.example",
                "ticker": None,
                "type": ctype,
            }
        )
    return out


def build_schools(rng: random.Random) -> list[dict[str, Any]]:
    out = []
    for name, slug, stype, city_idx, coarse in SCHOOLS:
        c = CITIES[city_idx]
        if coarse:  # PDL often emits only continent + country for schools
            loc = {
                "name": c[2],
                "locality": None,
                "region": None,
                "country": c[2],
                "continent": c[3],
            }
        else:
            loc = {
                "name": city_name(c),
                "locality": c[0],
                "region": c[1],
                "country": c[2],
                "continent": c[3],
            }
        out.append(
            {
                "name": name.lower(),
                "type": stype,
                "id": pdl_id(rng),
                "location": loc,
                "linkedin_url": f"linkedin.com/school/{slug}-example",
                "facebook_url": f"facebook.com/{slug}-example" if rng.random() < 0.5 else None,
                "twitter_url": None,
                "linkedin_id": str(rng.randint(10_000, 9_999_999)),
                "website": f"{slug}.example",
                "domain": f"{slug}.example",
            }
        )
    return out


# ─────────────────────────────────────────────────────────────────────────────
# Person record
# ─────────────────────────────────────────────────────────────────────────────


def build_experience(rng: random.Random, companies: list[dict[str, Any]]) -> list[dict[str, Any]]:
    n = rng.choices([0, 1, 2, 3, 4, 5], weights=[4, 18, 28, 26, 16, 8])[0]
    if n == 0:
        return []
    year = rng.randint(1998, 2022 - 2 * n)
    current = rng.random() < 0.85
    entries: list[dict[str, Any]] = []
    for i in range(n):
        last = i == n - 1
        start = year
        year = min(2025, year + rng.randint(1, 5))
        end = None if (last and current) else year
        company = None if rng.random() < 0.05 else rng.choice(companies)  # freelance / no company
        title = rng.choice(TITLES)
        entry = {
            "company": company,
            "location_names": [company["location"]["name"]]
            if company and company["location"]
            else [],
            "end_date": fmt_date(rng, end) if end else None,
            "start_date": fmt_date(rng, start) if rng.random() < 0.95 else None,
            "title": {
                "name": title[0],
                "class": title[3],
                "role": title[1],
                "sub_role": title[2],
                "levels": list(title[4]),
            },
            "is_primary": False,
            "summary": None,
        }
        entries.append(entry)
        # Promotion: same company + same start year, new title (kept as 2 rows).
        if company and rng.random() < 0.08:
            promo = json.loads(json.dumps(entry))
            promo["title"]["name"] = (
                "lead " if title[0].startswith("senior") else "senior "
            ) + title[0]
            promo["title"]["levels"] = ["senior"]
            entries.append(promo)
    entries[-1]["is_primary"] = True
    # A current side role alongside the primary one.
    if current and rng.random() < 0.06:
        side = rng.choice(companies)
        entries.append(
            {
                "company": side,
                "location_names": [],
                "end_date": None,
                "start_date": fmt_date(rng, 2023),
                "title": {
                    "name": "advisor",
                    "class": "services",
                    "role": "advisory",
                    "sub_role": None,
                    "levels": [],
                },
                "is_primary": False,
                "summary": None,
            }
        )
    # Exact duplicate entry (PDL merges sources) — collapsed by *_unique.
    if rng.random() < 0.05:
        entries.append(json.loads(json.dumps(entries[0])))
    rng.shuffle(entries)  # PDL array order isn't chronological
    return entries


def build_education(rng: random.Random, schools: list[dict[str, Any]]) -> list[dict[str, Any]]:
    n = rng.choices([0, 1, 2, 3], weights=[12, 45, 33, 10])[0]
    out = []
    year = rng.randint(1985, 2015)
    for _ in range(n):
        degrees, majors = rng.choice(DEGREES)
        school = rng.choice(schools)
        if rng.random() < 0.05:  # school known by name only, no PDL id
            school = {
                "name": "online coursework",
                "type": None,
                "id": None,
                "location": None,
                "linkedin_url": None,
                "facebook_url": None,
                "twitter_url": None,
                "linkedin_id": None,
                "website": None,
                "domain": None,
            }
        length = 2 if degrees and degrees[0] in ("masters", "associates") else 4
        out.append(
            {
                "school": school,
                "degrees": list(degrees),
                "start_date": str(year) if rng.random() < 0.9 else None,
                "end_date": str(year + length) if rng.random() < 0.9 else None,
                "majors": list(majors),
                "minors": [rng.choice(MINORS)] if rng.random() < 0.15 else [],
                "gpa": round(rng.uniform(2.8, 4.0), 2) if rng.random() < 0.1 else None,
                "summary": None,
            }
        )
        year += length + rng.randint(0, 4)
    if out and rng.random() < 0.05:  # duplicate education entry
        out.append(json.loads(json.dumps(out[0])))
    return out


def build_person(
    rng: random.Random, n: int, companies: list[dict[str, Any]], schools: list[dict[str, Any]]
) -> dict[str, Any]:
    first, sex = rng.choice(FIRST_NAMES)
    last = rng.choice(LAST_NAMES)
    middle = rng.choice(MIDDLE_NAMES) if rng.random() < 0.15 else None
    full = " ".join(p for p in (first, middle, last) if p).lower()
    username = f"{ascii_slug(first)}-{ascii_slug(last)}-{n}"
    linkedin_id = str(rng.randint(10_000_000, 999_999_999))

    experience = build_experience(rng, companies)
    education = build_education(rng, schools)
    primary = next((e for e in experience if e["is_primary"]), None)
    pco = primary["company"] if primary else None
    ptitle = primary["title"] if primary else None

    home = rng.choice(CITIES) if rng.random() < 0.92 else None
    past = rng.sample(CITIES, rng.choice([0, 0, 1, 2]))
    cities = ([home] if home else []) + [c for c in past if c != home]
    location_names = [city_name(c) for c in cities]
    regions = list(dict.fromkeys(f"{c[1]}, {c[2]}" for c in cities))
    countries = list(dict.fromkeys(c[2] for c in cities))

    industry = (
        pco["industry"] if pco else (rng.choice(INDUSTRIES)[0] if rng.random() < 0.5 else None)
    )
    skills = rng.sample(SKILLS, rng.choice([0, 2, 3, 5, 8]))
    interests = rng.sample(INTERESTS, rng.choice([0, 0, 1, 3]))
    onet = ONET.get(ptitle["role"]) if ptitle else None
    pcl = pco["location"] if pco else None

    headline_kind = rng.random()
    if ptitle and pco and headline_kind < 0.5:
        headline = f"{ptitle['name']} at {pco['name']}"
    elif headline_kind < 0.75:
        headline = placeholder(rng)
    else:
        headline = None
    summary = None
    if ptitle and rng.random() < 0.3:
        tmpl = rng.choice(SUMMARY_TEMPLATES)
        s1, s2 = rng.sample(SKILLS, 2)
        summary = tmpl.format(
            title=ptitle["name"], industry=industry or "several industries", skill=s1, skill2=s2
        )

    ts = f"2025-{rng.randint(1, 12):02d}-{rng.randint(1, 28):02d}"
    return {
        "id": pdl_id(rng),
        "full_name": full,
        "first_name": first.lower(),
        "middle_initial": middle[0].lower() if middle else None,
        "middle_name": middle.lower() if middle else None,
        "last_initial": last[0].lower(),
        "last_name": last.lower(),
        "sex": sex if rng.random() < 0.9 else None,
        "birth_year": placeholder(rng),
        "birth_date": placeholder(rng),
        "linkedin_url": f"linkedin.com/in/{username}",
        "linkedin_username": username,
        "linkedin_id": linkedin_id,
        "facebook_url": placeholder(rng),
        "facebook_username": placeholder(rng),
        "facebook_id": placeholder(rng),
        "twitter_url": placeholder(rng),
        "twitter_username": placeholder(rng),
        "github_url": placeholder(rng),
        "github_username": placeholder(rng),
        "work_email": f"{ascii_slug(first)}.{ascii_slug(last)}{n}@example.com"
        if rng.random() < 0.25
        else None,
        "mobile_phone": placeholder(rng),
        "personal_emails": placeholder(rng),
        "recommended_personal_email": placeholder(rng),
        "industry": industry,
        "headline": headline,
        "summary": summary,
        "inferred_salary": rng.choice(SALARIES) if rng.random() < 0.8 else None,
        "job_title": ptitle["name"] if ptitle else None,
        "job_title_role": ptitle["role"] if ptitle else None,
        "job_title_sub_role": ptitle["sub_role"] if ptitle else None,
        "job_title_class": ptitle["class"] if ptitle else None,
        "job_title_levels": list(ptitle["levels"]) if ptitle else [],
        "job_onet_code": onet[0] if onet else None,
        "job_onet_major_group": onet[1] if onet else None,
        "job_onet_minor_group": onet[2] if onet else None,
        "job_onet_broad_occupation": onet[3] if onet else None,
        "job_onet_specific_occupation": onet[4] if onet else None,
        "job_onet_specific_occupation_detail": None,
        "job_company_id": pco["id"] if pco else None,
        "job_company_name": pco["name"] if pco else None,
        "job_company_website": pco["website"] if pco else None,
        "job_company_size": pco["size"] if pco else None,
        "job_company_founded": pco["founded"] if pco else None,
        "job_company_industry": pco["industry"] if pco else None,
        "job_company_industry_v2": pco["industry_v2"] if pco else None,
        "job_company_type": pco["type"] if pco else None,
        "job_company_ticker": None,
        "job_company_linkedin_url": pco["linkedin_url"] if pco else None,
        "job_company_linkedin_id": pco["linkedin_id"] if pco else None,
        "job_company_facebook_url": pco["facebook_url"] if pco else None,
        "job_company_twitter_url": pco["twitter_url"] if pco else None,
        "job_company_location_name": pcl["name"] if pcl else None,
        "job_company_location_locality": pcl["locality"] if pcl else None,
        "job_company_location_metro": pcl["metro"] if pcl else None,
        "job_company_location_region": pcl["region"] if pcl else None,
        "job_company_location_geo": pcl["geo"] if pcl else None,
        "job_company_location_street_address": pcl["street_address"] if pcl else None,
        "job_company_location_address_line_2": pcl["address_line_2"] if pcl else None,
        "job_company_location_postal_code": pcl["postal_code"] if pcl else None,
        "job_company_location_country": pcl["country"] if pcl else None,
        "job_company_location_continent": pcl["continent"] if pcl else None,
        "job_start_date": primary["start_date"] if primary else None,
        "job_summary": None,
        "job_last_changed": ts if primary else None,
        "job_last_verified": ts if primary else None,
        "location_name": city_name(home) if home else None,
        "location_locality": home[0] if home else None,
        "location_metro": home[4] if home else None,
        "location_region": home[1] if home else None,
        "location_country": home[2] if home else None,
        "location_continent": home[3] if home else None,
        "location_street_address": placeholder(rng),
        "location_address_line_2": placeholder(rng),
        "location_postal_code": home[6] if home and rng.random() < 0.5 else None,
        "location_geo": home[5] if home else None,
        "location_last_updated": ts if home else None,
        "street_addresses": placeholder(rng),
        "location_names": location_names,
        "regions": regions,
        "countries": countries,
        "interests": interests,
        "skills": skills,
        "experience": experience,
        "education": education,
        "profiles": [
            {
                "network": "linkedin",
                "id": linkedin_id,
                "url": f"linkedin.com/in/{username}",
                "username": username,
            }
        ],
        "dataset_version": DATASET_VERSION,
        "operation_id": hexid(rng, 64),
    }


def generate(seed: int, persons: int) -> list[dict[str, Any]]:
    rng = random.Random(seed)  # noqa: S311 — deterministic fake data, not crypto
    companies = build_companies(rng)
    schools = build_schools(rng)
    records = [build_person(rng, n, companies, schools) for n in range(1, persons + 1)]
    # Same pdl_id delivered twice (PDL part files overlap) — pdl_person_unique
    # and the other *_unique models must collapse these.
    for i in (7, 42):
        if i < len(records):
            dup = json.loads(json.dumps(records[i]))
            dup["job_last_verified"] = "2025-12-01" if dup["job_last_verified"] else None
            records.append(dup)
    return records


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--output", default="infra/local/fixtures/pdl-person-sample-v1.csv.gz")
    p.add_argument("--persons", type=int, default=200)
    p.add_argument("--seed", type=int, default=20260522)
    args = p.parse_args()

    records = generate(args.seed, args.persons)
    with (
        open(args.output, "wb") as fh,
        gzip.GzipFile(filename="", mode="wb", fileobj=fh, mtime=0) as gz,
    ):
        for rec in records:
            gz.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
            gz.write(b"\n")
    print(f"wrote {len(records)} records to {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
