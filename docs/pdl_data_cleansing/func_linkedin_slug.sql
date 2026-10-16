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


-- cleansing_rad.func_linkedin_slug(text) ------------------------------------
--
-- Extracts the LinkedIn company slug from a linkedin_url — the portion after
-- `/company/`. Used by variant discovery to detect a slug family: a variant
-- company's slug typically starts with the canonical slug + '-' (e.g.
-- `acme-group-germany` starts with `acme-group-`).
--
-- Input examples:
--   https://www.linkedin.com/company/acme-group         → acme-group
--   http://linkedin.com/company/acme-group-germany/     → acme-group-germany
--   linkedin.com/company/foo?ref=bar#frag               → foo
--   linkedin.com/company/12345                          → 12345      (numeric id)
--
-- Rules:
--   1. Case-fold to lower.
--   2. Strip everything up to and including `/company/`.
--   3. Drop trailing slash, query string, fragment.
--   4. NULL / empty → NULL.
--
-- Deployment notes:
--   - IMMUTABLE  — safe in expression indexes.
--   - STRICT     — NULL input returns NULL.
-- ---------------------------------------------------------------------------

create or replace function cleansing_rad.func_linkedin_slug(url text)
  returns text
  language sql
  immutable
  strict
as $$
  select nullif(
    trim(both '/' from
      regexp_replace(
        regexp_replace(lower(url), '^.*linkedin\.com/company/', ''),
        '[?#].*$', ''
      )
    ),
    ''
  );
$$;


-- CHECK: sample linkedin_url values → slug
select url, cleansing_rad.func_linkedin_slug(url) as slug
  from (values
    ('https://www.linkedin.com/company/acme-group'::text),
    ('http://linkedin.com/company/acme-group-germany/'),
    ('linkedin.com/company/acme-group-italy'),
    ('linkedin.com/company/foo?ref=bar#frag'),
    ('linkedin.com/company/12345'),
    ('https://linkedin.com/COMPANY/Globex-Corp'),
    (null),
    ('')
  ) t(url);
