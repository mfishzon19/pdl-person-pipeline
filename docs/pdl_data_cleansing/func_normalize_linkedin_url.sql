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


-- cleansing_rad.func_normalize_linkedin_url(text) --------------------------------
--
-- Normalizes LinkedIn URLs for dedup / JOIN comparison.
--   1. NFC-fold + typographic → ASCII (rare but present in raw data —
--      a sample audit of raw.pdl_person found linkedin_url values with
--      curly apostrophes and combining marks, likely preserved from
--      user-authored vanity URLs).
--   2. Lowercase.
--   3. Strip protocol prefix (http:// or https://).
--   4. Strip 'www.' subdomain prefix if present.
--   5. Strip trailing slash.
--
-- All these variants collapse to the same value  linkedin.com/in/johndoe :
--   https://www.linkedin.com/in/JohnDoe/
--   http://linkedin.com/in/johndoe
--   LinkedIn.com/in/johndoe
--   linkedin.com/in/johndoe/
--
-- Does NOT strip query params (LinkedIn URLs in PDL data rarely have them).
-- Add a regexp_replace for '?' onward if that changes.
--
-- Intended for: person_dedup_on_linkedin.sql, which PARTITIONs BY the
--          LinkedIn URL. It would replace the  lower(p.linkedin_url)
--          expression that script currently uses.
--
-- Deployment notes:
--   - IMMUTABLE  — safe in generated columns and expression indexes. Consider
--     adding an expression index if the dedup query runs repeatedly:
--       create index on integration.person
--         (cleansing_rad.func_normalize_linkedin_url(linkedin_url));
--   - STRICT     — NULL input returns NULL immediately.
--   - Fast       — one NFC + one translate + one lowercase + one regexp_replace + one rtrim.
--
-- Placement:
--   - For exploration: run this file before any script that calls it.
--   - Long-term: a Flyway repeatable migration (R__func_*.sql; see
--     docs/design/21_cleansing_layer_design.md §5). Same body.
-- ---------------------------------------------------------------------------

create or replace function cleansing_rad.func_normalize_linkedin_url(url text)
  returns text
  language sql
  immutable
  strict
as $$
  select rtrim(
           regexp_replace(
             lower(
               translate(
                 normalize(url, NFC),
                 U&'\2018\2019\201A\201B\201C\201D\2013\2014\2015\00B4\0060',
                   '''''''''""---'''
               )
             ),
             '^https?://(www\.)?',
             ''
           ),
           '/'
         );
$$;


-- CHECK: sample inputs → normalized outputs
select
  original,
  cleansing_rad.func_normalize_linkedin_url(original) as normalized
  from (values
    ('https://www.linkedin.com/in/JohnDoe/'::text),    --full canonical: protocol, www, mixed case, trailing slash
    ('http://linkedin.com/in/janeSmith'),              --http, no www
    ('LinkedIn.com/in/user/'),                         --no protocol, host case-mixed
    ('linkedin.com/in/o’brien'),                       --curly apostrophe → straight
    ('https://WWW.LINKEDIN.COM/in/ExampleUser'),       --all uppercase
    (null)                                             --NULL → NULL (STRICT)
  ) t(original);

