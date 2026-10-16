{{ config(severity='warn') }}

-- Singular test: detect ANY cycle (2-cycle, 3-cycle, N-cycle) in
-- catalog.pdl_id_aliases via recursive walk.
--
-- severity='warn' — fires as a dbt warning but does NOT fail the build.
-- The model canonicalizes 2-cycle members to their lexicographically
-- smallest pdl_id (see pdl_person_unique.sql), so 2-cycles don't leak
-- duplicate rows into pdl_person_unique; longer cycles are not
-- canonicalized. This test surfaces every cycle for operator visibility
-- on every run. The recursive walk finds a node that revisits its own
-- start within the hop limit, so it catches cycles of any length.
--
-- A cycle means PDL has emitted contradictory alias rows across deliveries
-- — e.g., delivery N: A → B; delivery N+M: B → A. Both directions can't
-- simultaneously be authoritative. 2-cycles occur occasionally in real
-- deliveries; a longer cycle would show up here via cycle_starts_at.
--
-- The recursive walk uses the same hops<10 + visited-set guard pattern as
-- pdl_person_unique.sql's resolver. A node detected as "would-revisit"
-- means the walk has found a cycle.

WITH RECURSIVE walk AS (
  -- Base: every alias row, 1 hop. Track the start (root) and the path.
  SELECT old_pdl_id     AS start_pdl_id,
         current_pdl_id AS at_pdl_id,
         1              AS hops,
         ARRAY[old_pdl_id, current_pdl_id] AS visited
  FROM   {{ source('catalog', 'pdl_id_aliases') }}

  UNION ALL

  -- Recurse forward. Stop walking when:
  --   - we've gone > 10 hops (defensive cap), OR
  --   - the next current_pdl_id is already in `visited` (cycle detected).
  -- We don't emit the cycle-closing step; we emit the row up to that point.
  -- The visited array preserves cycle members.
  SELECT w.start_pdl_id,
         a.current_pdl_id,
         w.hops + 1,
         w.visited || a.current_pdl_id
  FROM   walk w
  JOIN   {{ source('catalog', 'pdl_id_aliases') }} a
    ON   a.old_pdl_id = w.at_pdl_id
  WHERE  w.hops < 10
    AND  NOT (a.current_pdl_id = ANY(w.visited))
)

-- A cycle exists for `start_pdl_id` iff its walk reaches a state where
-- the NEXT step would revisit `start_pdl_id`. Equivalently: there exists
-- an alias row `a.old = at, a.current = start` reachable from this walk.
SELECT DISTINCT
       w.start_pdl_id  AS cycle_starts_at,
       w.at_pdl_id     AS cycle_closes_via,
       w.hops          AS cycle_length
FROM   walk w
WHERE  EXISTS (
  SELECT 1
  FROM   {{ source('catalog', 'pdl_id_aliases') }} a
  WHERE  a.old_pdl_id     = w.at_pdl_id
    AND  a.current_pdl_id = w.start_pdl_id
)
