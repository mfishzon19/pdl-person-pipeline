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


-----------------INVALID NAME FILTER — TABLES + CHECKS--------------

-- Splits integration.person into:
--   cleansing_rad.person_valid_name    — name looks like an actual person's name
--   cleansing_rad.person_invalid_name  — name is a professional title, placeholder,
--                                        or contains a non-Latin script character
--
-- Name fields are CHARACTER-NORMALIZED before classification and storage via
-- cleansing_rad.func_normalize_person_name(text):
--   - NFC-folds decomposed Unicode into precomposed form
--     (e.g., 'i' + combining dot U+0307  →  'İ' U+0130)
--   - Replaces typographic punctuation with ASCII
--     (curly apostrophe/quote → straight; en/em-dash → hyphen; grave/acute → ')
--   - Trims + collapses whitespace runs
--
-- Both classification regex checks AND the stored column values use the
-- normalized form. Original (raw) values remain available on integration.person
-- via id lookup if provenance ever needs to be recovered.
--
-- Two flag columns drive the split:
--   name_is_title       — first / last / full name is a professional title
--                         / credential or placeholder (esquire, phd, mba,
--                         admin, test, na, nil, unknown, the company, etc.)
--   name_has_non_latin  — first / last / full name contains a character from
--                         a non-Latin script block (Cyrillic, Armenian, Hebrew,
--                         Arabic, Devanagari/Bengali/Tamil/other Indic, Thai,
--                         Lao, Georgian, CJK, Hiragana, Katakana, Hangul).
--                         Blocklist rather than whitelist — legitimate Latin
--                         names using typographic punctuation or decomposed
--                         diacritics pass through cleanly (also handled by
--                         upstream normalization).
--
-- NULL flags treated as false — a NULL name field doesn't reject the row.
--
-- DEPENDENCY: cleansing_rad.func_normalize_person_name — deploy via
--             func_normalize_person_name.sql before running this script.


-- BUILD ----------------------------------------------------------------------

drop table if exists cleansing_rad.person_valid_name cascade;
drop table if exists cleansing_rad.person_invalid_name cascade;

--valid names: no flag was TRUE (neither title-shape nor non-Latin script)
create table cleansing_rad.person_valid_name as
with normalized as (
  select p.id,
         cleansing_rad.func_normalize_person_name(p.first_name) as first_name,
         cleansing_rad.func_normalize_person_name(p.last_name)  as last_name,
         cleansing_rad.func_normalize_person_name(p.full_name)  as full_name
    from integration.person p
),
named as (
  select n.id,
         n.first_name,
         n.last_name,
         n.full_name,
         (lower(n.first_name) ~ '^(esq|esquire|jd|llb|llm|phd|mba|cpa|admin|administrator|test|testing|unknown|n/?a|null|none|nil|user|first|last|name|firstname|lastname|no name|full name|the company|the office|not available|not applicable|not provided|blocked)$'
          or lower(n.last_name)  ~ '^(esq|esquire|jd|llb|llm|phd|mba|cpa|admin|administrator|test|testing|unknown|n/?a|null|none|nil|user|first|last|name|firstname|lastname|no name|full name|the company|the office|not available|not applicable|not provided|blocked)$'
          or lower(n.full_name)  ~ '^(esq|esquire|jd|llb|llm|phd|mba|cpa|admin|administrator|test|testing|unknown|n/?a|null|none|nil|user|first|last|name|firstname|lastname|no name|full name|the company|the office|not available|not applicable|not provided|blocked)$'
         )                                                         as name_is_title,
         (n.first_name ~ '[Ѐ-ۿऀ-෿฀-໿Ⴀ-ჿ　-鿿가-힯]'
          or n.last_name  ~ '[Ѐ-ۿऀ-෿฀-໿Ⴀ-ჿ　-鿿가-힯]'
          or n.full_name  ~ '[Ѐ-ۿऀ-෿฀-໿Ⴀ-ჿ　-鿿가-힯]'
         )                                                         as name_has_non_latin
    from normalized n
)
select id, first_name, last_name, full_name
  from named
 where name_is_title      is not true
   and name_has_non_latin is not true;

--invalid names: caught by at least one flag (flags kept in output for review)
create table cleansing_rad.person_invalid_name as
with normalized as (
  select p.id,
         cleansing_rad.func_normalize_person_name(p.first_name) as first_name,
         cleansing_rad.func_normalize_person_name(p.last_name)  as last_name,
         cleansing_rad.func_normalize_person_name(p.full_name)  as full_name
    from integration.person p
),
named as (
  select n.id,
         n.first_name,
         n.last_name,
         n.full_name,
         (lower(n.first_name) ~ '^(esq|esquire|jd|llb|llm|phd|mba|cpa|admin|administrator|test|testing|unknown|n/?a|null|none|nil|user|first|last|name|firstname|lastname|no name|full name|the company|the office|not available|not applicable|not provided|blocked)$'
          or lower(n.last_name)  ~ '^(esq|esquire|jd|llb|llm|phd|mba|cpa|admin|administrator|test|testing|unknown|n/?a|null|none|nil|user|first|last|name|firstname|lastname|no name|full name|the company|the office|not available|not applicable|not provided|blocked)$'
          or lower(n.full_name)  ~ '^(esq|esquire|jd|llb|llm|phd|mba|cpa|admin|administrator|test|testing|unknown|n/?a|null|none|nil|user|first|last|name|firstname|lastname|no name|full name|the company|the office|not available|not applicable|not provided|blocked)$'
         )                                                         as name_is_title,
         (n.first_name ~ '[Ѐ-ۿऀ-෿฀-໿Ⴀ-ჿ　-鿿가-힯]'
          or n.last_name  ~ '[Ѐ-ۿऀ-෿฀-໿Ⴀ-ჿ　-鿿가-힯]'
          or n.full_name  ~ '[Ѐ-ۿऀ-෿฀-໿Ⴀ-ჿ　-鿿가-힯]'
         )                                                         as name_has_non_latin
    from normalized n
)
select id, first_name, last_name, full_name, name_is_title, name_has_non_latin
  from named
 where name_is_title      is true
    or name_has_non_latin is true;

--indexes + stats
create unique index person_valid_name_id_key
  on cleansing_rad.person_valid_name (id);
create unique index person_invalid_name_id_key
  on cleansing_rad.person_invalid_name (id);
analyze cleansing_rad.person_valid_name;
analyze cleansing_rad.person_invalid_name;


-- CHECKS ---------------------------------------------------------------------

--1. row-count sanity — valid + invalid should sum to integration.person total
select
  (select count(*) from integration.person)                              as total_person,
  (select count(*) from cleansing_rad.person_valid_name)                   as valid,
  (select count(*) from cleansing_rad.person_invalid_name)                 as invalid,
  (select count(*) from cleansing_rad.person_valid_name)
    + (select count(*) from cleansing_rad.person_invalid_name)             as valid_plus_invalid;

--2. invalid breakdown — how many rejected by each flag (some rows caught by both)
select
  count(*)                                             as invalid_total,
  count(*) filter (where name_is_title)                as by_title,
  count(*) filter (where name_has_non_latin)           as by_non_latin,
  count(*) filter (where name_is_title and name_has_non_latin) as by_both;

--3. sample of VALID names (random 100 — mostly ordinary human names,
--   eyeball to make sure the filter isn't dropping legit people)
select *
  from cleansing_rad.person_valid_name
 order by random()
 limit 100;

--4. sample of INVALID names (random 100 — flags visible so you can see
--   WHY each row was rejected)
select *
  from cleansing_rad.person_invalid_name
 order by random()
 limit 100;

--5. sample of INVALID caught by title-only (not non-Latin) — the
--   professional-title/placeholder junk
select *
  from cleansing_rad.person_invalid_name
 where name_is_title
   and not name_has_non_latin
 order by random()
 limit 100;

--6. sample of INVALID caught by non-Latin only (not title) —
--   Chinese / Japanese / Korean / Arabic / Cyrillic / etc. names
select *
  from cleansing_rad.person_invalid_name
 where name_has_non_latin
   and not name_is_title
 order by random()
 limit 100;
