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


-------------------SCHOOL CANONICAL ROLLUP — TABLES + CHECKS-----------------

-- Builds two rollup artifacts on integration.school:
--
--   cleansing_rad.school_canonical      — one row per canonical school
--   cleansing_rad.school_canonical_map  — every integration.school.id → its
--                                         canonical (mapping table for JOINs)
--
-- Rollup key = (domain, type, subunit):
--   domain   — PDL-supplied school domain. Isolates the institution.
--   type     — PDL classification. Separates K-12 from universities.
--   subunit  — cleansing_rad.func_school_subunit(). Splits same-domain rows
--              into distinct sub-schools (law / business / medical / ...).
--
-- ROLLUP CLASSES:
--   Rollup-friendly (variants collapse to one canonical):
--     law, business, medical, public_health, public_policy, education,
--     divinity, engineering, design_architecture, nursing, pharmacy,
--     veterinary, journalism, social_work, arts, environment, military,
--     k12, community_college_or_vocational, training_or_bootcamp,
--     extension_or_continuing_ed, online, summer, university
--   Preserve-identity (each row stays its own canonical — long-tail entities
--   whose names are semantically distinct even when they match the same
--   subunit pattern):
--     center_or_institute, alumni_or_club, student_org, conference
--
-- NULL-domain schools are self-canonical.


-- 1. SUBUNIT CLASSIFIER ------------------------------------------------------
-- Name+domain+type-based. Global (no per-university enumeration).
--
-- CASE order rationale:
--   1. Non-academic meta types (alumni_or_club / student_org / conference)
--      go FIRST. Names like "Example Business School Alumni Angels of Sweden"
--      contain both meta ("alumni") and academic ("business school") tokens;
--      the entity IS an alumni chapter, not the business school. Meta wins.
--   2. Academic sub-schools (law / business / medical / ...) next. These are
--      real institutional units — variants collapse to a single canonical.
--   3. Military / K-12 / community college / vocational. Real schools of
--      different levels.
--   4. Extension / online / summer / training_or_bootcamp. Delivery modes.
--   5. center_or_institute is the LAST specific bucket — after academic. A
--      center at a law school is genuinely PART of that law school; roll it
--      up to `law` rather than preserve it as its own entity. Contrast with
--      alumni chapters, which are semantically distinct entities.
--   6. Fallthrough: 'university' (main campus / unclassified).
create or replace function cleansing_rad.func_school_subunit(domain text, type text, name text)
  returns text
  language sql
  immutable
  strict
as $$
  select case
    --NON-ACADEMIC META TYPES — check FIRST so "<X> Business School Alumni
    --Chapter of Y" is classified as alumni, not business
    when lower(name) ~ '\y(alumni|club|association of|angels of|chapter of|network of|society of|society for)\y'
         or lower(coalesce(domain,'')) ~ 'club|alum'                                                then 'alumni_or_club'
    when lower(name) ~ '\y(student club|student union|student association|undergraduate association|undergraduate research)\y' then 'student_org'
    when lower(name) ~ '\y(forum|roundtable|symposium|conference|summit|congress|convention|workshop|colloquium)\y' then 'conference'

    --Professional / graduate schools
    when lower(name) ~ '\y(law school|school of law)\y'                                            then 'law'
    when lower(name) ~ '\y(business school|school of business|graduate school of business|school of management|sloan|kellogg|wharton|booth|stern school|tuck school|fuqua school|anderson school|marshall school|ross school)\y' then 'business'
    when lower(name) ~ '\y(medical school|school of medicine|dental medicine|school of dentistry|hospital|medical center|health system)\y'
         or lower(coalesce(domain,'')) ~ 'hospital|medical|clinic'                                 then 'medical'
    when lower(name) ~ '\y(school of public health|chan school)\y'                                 then 'public_health'
    when lower(name) ~ '\y(kennedy school|school of government|school of public policy|goldman school|maxwell school|humphrey school|ford school|mccourt school)\y' then 'public_policy'
    when lower(name) ~ '\y(school of education|graduate school of education|teachers college)\y'  then 'education'
    when lower(name) ~ '\y(divinity|school of theology|theological seminary|yeshiva|rabbinical|seminary|church|synagogue|mosque|ministry|parish|christian|catholic|jewish|islamic)\y'
         or lower(coalesce(domain,'')) ~ 'church|synagogue|mosque|christian|catholic|jewish|islamic|religious' then 'divinity'
    when lower(name) ~ '\y(school of engineering|engineering school|paulson school|whiting school|viterbi school|pratt school|mccormick school|tandon school|jacobs school)\y' then 'engineering'
    when lower(name) ~ '\y(graduate school of design|school of design|school of architecture)\y'  then 'design_architecture'
    when lower(name) ~ '\y(school of nursing|nursing school)\y'                                    then 'nursing'
    when lower(name) ~ '\y(school of pharmacy)\y'                                                  then 'pharmacy'
    when lower(name) ~ '\y(school of veterinary)\y'                                                then 'veterinary'
    when lower(name) ~ '\y(school of journalism|graduate school of journalism)\y'                  then 'journalism'
    when lower(name) ~ '\y(school of social work)\y'                                               then 'social_work'
    when lower(name) ~ '\y(school of the arts|school of fine arts|conservatory|school of drama|school of music)\y' then 'arts'
    when lower(name) ~ '\y(school of the environment|environmental studies|nicholas school)\y'    then 'environment'

    --Military academies — check BEFORE k12 since 'academy' is ambiguous
    when lower(name) ~ '\y(naval academy|air force academy|military academy|coast guard academy|west point)\y'
         or lower(coalesce(domain,'')) ~ '\.mil$|\.mil/'                                            then 'military'

    --K-12 — trust the PDL `type` field first; name-based fallback for mislabels
    when lower(coalesce(type,'')) in ('secondary school','primary school')
         or lower(name) ~ '\y(high school|middle school|elementary school|kindergarten|preschool|pre-school|prep school|primary school)\y' then 'k12'

    --Community college / technical / vocational
    when lower(name) ~ '\y(community college|technical college|junior college|vocational|trade school)\y' then 'community_college_or_vocational'

    --Delivery-mode buckets
    when lower(name) ~ '\y(extension school|extension program|continuing education|professional studies|professional (& |and )?executive development)\y' then 'extension_or_continuing_ed'
    when lower(name) ~ '\y(online|edx|hmx|coursera)\y'                                              then 'online'
    when lower(name) ~ '\y(summer school|summer session|summer program)\y'                          then 'summer'
    when lower(name) ~ '\y(bootcamp|boot camp|coding academy|coding bootcamp|codecademy)\y'
         or lower(coalesce(domain,'')) ~ 'bootcamp|training'                                        then 'training_or_bootcamp'

    --Centers / institutes / clinics / programs / initiatives — check LAST so
    --these correctly roll up to their parent academic bucket (e.g. "Center
    --for X at Example Law School" → law, not preserved separately)
    when lower(name) ~ '\y(center|institute|clinic|lab|laboratory|program on|initiative)\y' then 'center_or_institute'

    else 'university'
  end;
$$;


-- 2. CANONICAL TABLE — grouped by (domain, type, subunit) with preserve-identity
--    fork for center_or_institute / alumni_or_club / student_org / conference
--    (each such row becomes its own canonical to avoid one center's name
--     dominating unrelated centers)
drop table if exists cleansing_rad.school_canonical cascade;

create table cleansing_rad.school_canonical as
with per_school as (
  select s.id,
         s.name,
         s.domain,
         s.type,
         cleansing_rad.func_school_subunit(lower(trim(s.domain)), s.type, s.name) as subunit,
         count(distinct pe.person_id)                                              as students_this_school
    from integration.school s
    left join integration.person_education pe on pe.school_id = s.id
   where s.domain is not null
   group by s.id, s.name, s.domain, s.type
)
select lower(trim(domain))                                                    as canonical_domain,
       type                                                                    as canonical_type,
       subunit                                                                 as canonical_subunit,
       min(id)                                                                 as canonical_id,
       count(*)                                                                as canonical_source_variants,
       sum(students_this_school)                                               as canonical_students,
       (array_agg(name order by students_this_school desc, length(name)))[1]   as canonical_name
  from per_school
 group by lower(trim(domain)),
          type,
          subunit,
          --preserve-identity fork: distinct grouping per-row for these subunits
          case when subunit in ('center_or_institute','alumni_or_club','student_org','conference')
               then id
               else 0
          end;


-- 3. MAP TABLE — every integration.school.id → its canonical
--    JOIN condition accounts for preserve-identity subunits by matching on
--    canonical_id when the subunit is one of those.
drop table if exists cleansing_rad.school_canonical_map cascade;

create table cleansing_rad.school_canonical_map as
with per_school_students as (
  select pe.school_id, count(distinct pe.person_id) as students
    from integration.person_education pe
   group by pe.school_id
)
--Part 1: domain-having schools → their canonical
select s.id                                    as original_id,
       s.name                                  as original_name,
       s.domain                                as original_domain,
       s.type                                  as original_type,
       cleansing_rad.func_school_subunit(lower(trim(s.domain)), s.type, s.name)
                                               as original_subunit,
       sc.canonical_id,
       sc.canonical_name,
       sc.canonical_domain,
       sc.canonical_type,
       sc.canonical_subunit,
       sc.canonical_source_variants,
       sc.canonical_students
  from integration.school s
  join cleansing_rad.school_canonical sc
    on sc.canonical_domain  = lower(trim(s.domain))
   and sc.canonical_type    = s.type
   and sc.canonical_subunit is not distinct from
       cleansing_rad.func_school_subunit(lower(trim(s.domain)), s.type, s.name)
   and (
         sc.canonical_subunit not in ('center_or_institute','alumni_or_club','student_org','conference')
         or sc.canonical_id = s.id
       )
 where s.domain is not null

union all

--Part 2: NULL-domain schools → self-canonical (no rollup)
select s.id,
       s.name,
       s.domain,
       s.type,
       null::text                              as original_subunit,
       s.id                                    as canonical_id,
       s.name                                  as canonical_name,
       null::text                              as canonical_domain,
       s.type                                  as canonical_type,
       null::text                              as canonical_subunit,
       1                                       as canonical_source_variants,
       coalesce(pss.students, 0)               as canonical_students
  from integration.school s
  left join per_school_students pss on pss.school_id = s.id
 where s.domain is null;


-- 4. INDEXES + STATS ---------------------------------------------------------
create unique index school_canonical_map_original_id_key
  on cleansing_rad.school_canonical_map (original_id);
create index school_canonical_map_canonical_id_idx
  on cleansing_rad.school_canonical_map (canonical_id);
create index school_canonical_map_canonical_domain_idx
  on cleansing_rad.school_canonical_map (canonical_domain);
analyze cleansing_rad.school_canonical;
analyze cleansing_rad.school_canonical_map;


-- =============================================================================
-- VERIFICATIONS
-- =============================================================================

-- V1. Row-count sanity
--     Confirms every integration.school row appears in the map exactly once.
--     `delta` should be 0. Non-zero = a JOIN in the map build lost or
--     duplicated rows.
select
  (select count(*) from integration.school)                as source_total,
  (select count(*) from cleansing_rad.school_canonical_map) as map_total,
  (select count(*) from cleansing_rad.school_canonical_map)
    - (select count(*) from integration.school)             as delta;


-- V2. Uniqueness of original_id in the map
--     Should return ZERO rows. Any row here means the same school got
--     mapped to multiple canonicals — bug in the JOIN.
select original_id, count(*)
  from cleansing_rad.school_canonical_map
 group by original_id
having count(*) > 1;


-- V3. Multi-university rollup — the (domain, subunit) breakdown for a few
--     large universities. Replace the domain list with the domains of the
--     largest universities in your data. Expect one row per sub-school
--     (law, business, medical, public_policy, extension, university, etc.).
--     If a large university shows only ONE row with subunit='university',
--     the classifier missed its sub-schools — extend the regex.
select canonical_domain,
       canonical_type,
       canonical_subunit,
       canonical_source_variants,
       canonical_students,
       canonical_name
  from cleansing_rad.school_canonical
 where canonical_domain in ('example.edu','example-business.edu','sample.edu')   -- CHANGE ME
 order by canonical_domain, canonical_students desc nulls last;


-- V4. Subunit distribution across ALL universities
--     Shows how much of the total student population lands in each subunit
--     bucket globally. If `university` dominates too heavily (the vast
--     majority of students), the classifier is missing patterns. If new buckets (k12, training,
--     divinity extension, etc.) show material volume, moderate cleanup
--     is working.
select canonical_subunit,
       count(*)                        as canonicals_in_bucket,
       sum(canonical_students)         as total_students,
       sum(canonical_source_variants)  as total_original_variants
  from cleansing_rad.school_canonical
 group by canonical_subunit
 order by total_students desc nulls last;


-- V5. Fallthrough sanity — 20 biggest schools that ended up in 'university'
--     These should be main-campus universities. If you see names that
--     CLEARLY indicate a sub-school (e.g. 'somewhere graduate school of
--     blah'), extend the classifier regex.
select canonical_domain, canonical_name, canonical_students
  from cleansing_rad.school_canonical
 where canonical_subunit = 'university'
 order by canonical_students desc
 limit 20;


-- V6. Deep-dive: full split of one university (replace the domains).
--     Shows every variant name and the subunit / canonical it was mapped to.
--     Preserve-identity subunits (center_or_institute etc.) should show
--     each row with its OWN canonical_name — not every center on the domain
--     collapsed into one.
select original_name,
       original_subunit,
       canonical_subunit,
       canonical_name,
       canonical_students
  from cleansing_rad.school_canonical_map
 where canonical_domain in ('example.edu','example-business.edu')   -- CHANGE ME
 order by canonical_subunit, canonical_students desc;


-- V7. Trace a specific variant through the mapping
--     For debugging a specific school name — see its original values +
--     which canonical it maps to. Change the LIKE pattern to trace others.
select *
  from cleansing_rad.school_canonical_map
 where lower(original_name) like '%career services center%';


-- V8. Subunit classifier smoke test — verify the regex on constructed inputs
--     Independent of the tables. Shows what the classifier returns for a
--     handful of common name/domain/type shapes. Useful when tuning the regex.
select input_domain, input_type, input_name,
       cleansing_rad.func_school_subunit(input_domain, input_type, input_name) as subunit
  from (values
    ('example.edu'::text, 'post-secondary institution'::text, 'Example University Law School'::text),
    ('example.edu',       'post-secondary institution',       'Example Center for Internet & Society at Example University'),
    ('example.edu',       'post-secondary institution',       'Example Center for Health and Human Rights at Example University'),
    ('sample.edu',        'post-secondary institution',       'Sample University School of Management'),
    ('sample.edu',        'post-secondary institution',       'Sample Graduate School of Business'),
    ('exampleprep.org',   'secondary school',                 'Example Preparatory School'),
    ('somehighschool.com','secondary school',                 'Example High School'),
    ('navy-example.edu',  'post-secondary institution',       'Example Naval Academy'),
    ('example.com',       'post-secondary institution',       'Example Community College'),
    ('bootcamp.io',       'post-secondary institution',       'Coding Bootcamp XYZ'),
    ('churchseminary.org','post-secondary institution',       'Example Theological Seminary'),
    ('example-alumni.org','post-secondary institution',       'Example Business School Alumni of Northern California'),
    ('examplehospital.org','post-secondary institution',      'Example General Hospital'),
    ('example.edu',       'post-secondary institution',       'Example University')
  ) t(input_domain, input_type, input_name);


-- V9. Every school anywhere in the map whose original name matches a
--     pattern (replace '%example%'). Wider than V6 — includes rows NOT on
--     the university's own domains.
select original_name,
       original_domain,
       --original_type,
       canonical_id,
       canonical_domain,
       canonical_subunit,
       canonical_name,
       canonical_source_variants,
       canonical_students
  from cleansing_rad.school_canonical_map
 where lower(original_name) like '%example%'   -- CHANGE ME
 order by canonical_subunit nulls last,
          canonical_students desc nulls last,
          original_name;


-- V10. Domain landscape for a name pattern
--      Shows every domain that hosts schools matching the name filter,
--      with per-domain rollup counts. Reveals the "wider family" beyond
--      the .edu domain (alumni chapters, teaching hospitals, standalone-
--      domain centers). Change '%example%' to any other pattern.
select original_domain,
       canonical_type,
       count(distinct original_id)                            as source_variants,
       count(distinct canonical_id)                           as distinct_canonicals,
       sum(canonical_students)                                as students
  from cleansing_rad.school_canonical_map
 where lower(original_name) like '%example%'                    -- CHANGE ME
    or lower(coalesce(original_domain, '')) like '%example%'
 group by original_domain, canonical_type
 order by students desc nulls last;


-- V11. Sample top 10 canonicals per new / extended subunit
--      Eyeball whether the classifier caught the right things. If a subunit
--      is dominated by unrelated entities, extend the regex to exclude them
--      or move them to a different bucket.
select canonical_subunit,
       canonical_name,
       canonical_domain,
       canonical_source_variants,
       canonical_students
  from (
    select canonical_subunit, canonical_name, canonical_domain,
           canonical_source_variants, canonical_students,
           row_number() over (partition by canonical_subunit
                              order by canonical_students desc nulls last) as rn
      from cleansing_rad.school_canonical
     where canonical_subunit in ('k12',
                                 'community_college_or_vocational',
                                 'training_or_bootcamp',
                                 'military',
                                 'divinity',
                                 'medical',
                                 'alumni_or_club',
                                 'center_or_institute',
                                 'conference')
  ) x
 where rn <= 10
 order by canonical_subunit, canonical_students desc nulls last;
