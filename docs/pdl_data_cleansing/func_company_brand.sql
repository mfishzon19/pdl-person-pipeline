-- =============================================================================
-- DISCLAIMER — EXPLORATORY / R&D CONTEXT
--
-- This file is part of the cleansing R&D. It reads from the integration
-- schema for convenience (run it against a local database where a PDL
-- delivery has already been built through integration.*).
--
-- In the target cleansing design, this logic must be applied UPSTREAM —
-- at the per-source `_cleaned` staging tier (between _unique and _staged),
-- BEFORE integration.* is populated. Cleansing on top of integration is a
-- convenience for exploration; it inverts the intended data flow.
--
-- Target design: docs/design/21_cleansing_layer_design.md
-- =============================================================================


-- cleansing_rad.func_company_brand(text) ------------------------------------
--
-- Extracts the "brand substring" from a company name — the distinctive core
-- with corporate-entity suffixes stripped. Used to match company names
-- across sources (e.g. a hierarchy spreadsheet vs PDL) and to discover
-- regional / office variants: a variant company shares the canonical
-- company's brand substring by LIKE match on its name, independent of
-- website / SLD.
--
-- Motivation: SLD-based matching misses cross-domain rebrands (a company
-- that moved from acme.com to acme-group.com) and false-positives on common
-- single-word SLDs (a town's website sharing a word with a company brand).
--
-- Rules:
--   1. Lowercase.
--   2. Strip a fixed set of corporate-entity suffixes when they appear as
--      standalone tokens: llp, l.l.p., plc, p.c., pc, pllc, ltd, limited,
--      inc, corp, co, llc, l.l.c., s.a., s.p.a., ag, gmbh,
--      pty (with optional " ltd"), and associates
--   3. Collapse internal whitespace runs.
--   4. Trim outer whitespace.
--
-- Deliberately NOT applied:
--   - Unicode normalization (do it upstream via func_normalize_company_name
--     if the input is user-generated)
--   - Country / office-location suffixes (Germany, UK, etc.) — those are
--     the very tokens that distinguish variants from the canonical
--
-- Deployment notes:
--   - IMMUTABLE  — safe in generated columns and expression indexes.
--   - STRICT     — NULL input returns NULL.
--
-- Placement:
--   - For exploration: run this file before any script that calls it.
--   - Long-term: a Flyway repeatable migration (R__func_*.sql; see
--     docs/design/21_cleansing_layer_design.md §5). Same body.
-- ---------------------------------------------------------------------------

create or replace function cleansing_rad.func_company_brand(nm text)
  returns text
  language sql
  immutable
  strict
as $$
  select trim(
    regexp_replace(
      regexp_replace(
        lower(nm),
        --Lookahead terminator ((?=...)) lets period-suffixed abbreviations
        --(p.c., l.l.p., s.a.) end at EOF without needing a word char after
        --the final period.
        '\y(?:l\.l\.p\.|p\.c\.|l\.l\.c\.|s\.a\.|s\.p\.a\.|llp|plc|pc|pllc|ltd|limited|inc|incorporated|corp|corporation|co|llc|ag|gmbh|pty(?:\s+ltd)?|and\s+associates)(?=\s|$|,|;)',
        '', 'gi'),
      '\s+', ' ', 'g'
    )
  );
$$;


-- CHECK: sample raw inputs
select original,
       cleansing_rad.func_company_brand(original) as brand
  from (values
    ('Acme & Partners P.C.'::text),
    ('Globex and Sons LLC'),
    ('INITECH HOLDINGS LLC'),
    ('Some Company Pty Ltd'),
    ('Foo Bar S.A.'),
    ('  Weird   Spacing  Inc  '),
    (null)
  ) t(original);
