{#-
  staging.pdl_person_unique — PDL person deduplicated + alias-resolved via
  recursive walk of catalog.pdl_id_aliases. One row per CURRENT pdl_id.

  Column set: the SELECT matches the DBML table shape exactly
  (on_schema_change='fail' rejects drift). Columns that duplicated other
  staging tables (job_* current-job fields → pdl_person_experience_parsed,
  location_* → pdl_person_addresses_parsed) and always-placeholder fields
  (non-LinkedIn social URL/id/username, mobile_phone, name_aliases) were
  dropped in V12 / V16; do not re-add them.

  What stays: provenance (partition_id, loaded_at), record metadata,
  pdl_id, names, bio, inferred, contact (work_email only), social-as-LinkedIn
  (linkedin_* cross-source join keys per docs/requirements/01 §4) plus
  facebook_friends (always-NULL int4 companion retained for now), and 5 jsonb
  text arrays (skills, interests, location_names, countries, regions).

  Alias resolution — RECURSIVE with 2-cycle canonicalization:
    PDL ships MERGED_RECORDS as person id pairs ({"id": "<old>", "merged_to":
    "<new>"}). raw.project_pdl_deltas() projects these into
    catalog.pdl_id_aliases (old_pdl_id, current_pdl_id).

    PDL re-merges pdl_ids across deliveries, so aliases form chains
    (A → B → C); single-hop resolution would leave records on stale ids.
    The recursive CTE below walks each chain to its terminal end.
    `hops < 10` is a safety guard against cycles or pathologically deep
    chains; the singular tests pdl_person_unique_alias_cycle_guard.sql
    and pdl_person_unique_alias_hop_cap.sql surface cycles and cap-hits
    respectively (both severity='warn').

    Cycle canonicalization (2-cycles only): if PDL emits A→B and B→A
    across deliveries, the recursive walk alone maps A→B and B→A each at
    1 hop — yielding TWO rows for what is the same person. The `two_cycles`
    CTE detects these pairs and maps BOTH members to LEAST(A, B),
    collapsing them into a single row (deterministic and stable across
    rebuilds). Longer cycles (A→B→C→A) are not canonicalized; the
    cycle-guard test surfaces them if they appear.

  Dedup ordering: ORDER BY resolved_pdl_id, loaded_at DESC, partition_id
  DESC (latest load wins), same as the other _unique tables.

  Source-of-truth: modeling/dbml/staging.dbml pdl_person_unique block.
  Design: docs/design/15_pdl_staging_design.md.
-#}

WITH RECURSIVE alias_chain AS (
  -- Base case: every alias row in the catalog, treated as 1 hop forward.
  -- The `visited` array tracks the path so far (start with both endpoints
  -- of the alias row) so the recursive step can detect cycles.
  SELECT old_pdl_id, current_pdl_id, 1 AS hops,
         ARRAY[old_pdl_id, current_pdl_id] AS visited
  FROM {{ source('catalog', 'pdl_id_aliases') }}

  UNION ALL

  -- Recursive case: if the current_pdl_id of an alias is ALSO an old_pdl_id
  -- elsewhere in the catalog, follow it forward (consolidating chains like
  -- A→B→C into A→C). Stop walking when:
  --   - the next current_pdl_id is already in `visited` (cycle detected), OR
  --   - we've walked 10 hops (pathologically deep chain; defensive cap).
  -- With the cycle stop, each member of a 2-cycle A↔B terminates at its
  -- first alias target (A→B, B→A); `two_cycles` below collapses the pair.
  SELECT ac.old_pdl_id, a.current_pdl_id, ac.hops + 1,
         ac.visited || a.current_pdl_id
  FROM alias_chain ac
  JOIN {{ source('catalog', 'pdl_id_aliases') }} a
    ON a.old_pdl_id = ac.current_pdl_id
  WHERE ac.hops < 10
    AND NOT (a.current_pdl_id = ANY(ac.visited))
),

terminal_alias AS (
  -- For each old_pdl_id, pick the row with max hops = the END of its chain.
  SELECT DISTINCT ON (old_pdl_id)
    old_pdl_id,
    current_pdl_id AS terminal_pdl_id
  FROM alias_chain
  ORDER BY old_pdl_id, hops DESC
),

two_cycles AS (
  -- Detect 2-cycle pairs (A→B and B→A both present in catalog). Both
  -- cycle members map to LEAST(A, B) — deterministic single canonical id.
  -- Without this, the naïve recursive walk would yield A→B at 1 hop and
  -- B→A at 1 hop, producing two pdl_person_unique rows for the same
  -- person. See the header comment block for the canonicalization rationale.
  SELECT a1.old_pdl_id AS cycle_member,
         LEAST(a1.old_pdl_id, a1.current_pdl_id) AS canonical
  FROM   {{ source('catalog', 'pdl_id_aliases') }} a1
  JOIN   {{ source('catalog', 'pdl_id_aliases') }} a2
    ON   a2.old_pdl_id     = a1.current_pdl_id
   AND   a2.current_pdl_id = a1.old_pdl_id
),

resolved AS (
  SELECT
    p.partition_id,
    p.loaded_at,
    -- Resolution precedence: cycle canonical > terminal of chain > raw pdl_id.
    -- two_cycles match consumes cycle members FIRST so they collapse to
    -- LEAST(A, B) rather than each walking 1-hop and ending at different ids.
    COALESCE(c.canonical, t.terminal_pdl_id, p.pdl_id) AS resolved_pdl_id,
    p.first_seen,
    p.num_sources,
    p.num_records,
    p.dataset_version,
    p.operation_id,
    p.first_name,
    p.middle_name,
    p.middle_initial,
    p.last_name,
    p.last_initial,
    p.full_name,
    p.headline,
    p.summary,
    p.industry,
    p.sex,
    p.inferred_years_experience,
    p.inferred_salary,
    p.work_email,
    p.job_last_changed,
    p.job_last_verified,
    p.location_last_updated,
    p.linkedin_id,
    p.linkedin_url,
    p.linkedin_username,
    p.linkedin_connections,
    p.facebook_friends,
    p.skills,
    p.interests,
    p.location_names,
    p.countries,
    p.regions
  FROM {{ ref('pdl_person_parsed') }} p
  LEFT JOIN two_cycles    c ON c.cycle_member = p.pdl_id
  LEFT JOIN terminal_alias t ON t.old_pdl_id  = p.pdl_id
)

SELECT DISTINCT ON (resolved_pdl_id)
    partition_id,
    loaded_at,
    resolved_pdl_id              AS pdl_id,
    first_seen,
    num_sources,
    num_records,
    dataset_version,
    operation_id,
    -- Names
    first_name,
    middle_name,
    middle_initial,
    last_name,
    last_initial,
    full_name,
    -- Bio
    headline,
    summary,
    industry,
    sex,
    -- Inferred
    inferred_years_experience,
    inferred_salary,
    -- Contact (PII-allowed subset)
    work_email,
    -- PDL freshness signals (V17). Not always populated; NULL when PDL
    -- omits them. integration.person casts these to timestamptz.
    job_last_changed,
    job_last_verified,
    location_last_updated,
    -- Social — LinkedIn (cross-source join key per docs/requirements/01 §4).
    -- facebook/twitter/github URL+id+username columns carried only boolean
    -- placeholders on this PDL subscription tier and were dropped in V16.
    -- facebook_friends (always-NULL int4) is kept in staging for now.
    linkedin_id,
    linkedin_url,
    linkedin_username,
    linkedin_connections,
    facebook_friends,
    -- Simple text arrays (jsonb; integration loaders unnest at consume time
    -- and dedup happens in the ref layer per docs/design/15 + ADR-0005).
    skills,
    interests,
    location_names,
    countries,
    regions
FROM resolved
ORDER BY resolved_pdl_id, loaded_at DESC, partition_id DESC
