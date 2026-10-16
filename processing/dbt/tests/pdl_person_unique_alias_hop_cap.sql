{{ config(severity='warn') }}

-- Singular test: surface alias chains that hit the recursive CTE's
-- hops=10 safety cap in pdl_person_unique.sql.
--
-- severity='warn' — fires as a dbt warning but does NOT fail the build.
-- The recursive resolver in pdl_person_unique.sql stops walking at
-- 10 hops as a defensive guard against pathological chains. If a chain
-- truly hits the cap, the affected pdl_id maps to its 10th-hop
-- intermediate, NOT its terminal — silent stale-id leakage.
--
-- This test makes that condition visible. Observed chains are only a few
-- hops long, so the cap is well above expected depth. If the warning ever
-- fires, raise the cap (and investigate why chains are growing).
--
-- Complements pdl_person_unique_alias_cycle_guard.sql — cycles cause
-- the walk to stop on revisit (caught by that test); cap-hits are a
-- separate failure mode (depth, not revisit).

WITH RECURSIVE walk AS (
  SELECT old_pdl_id, current_pdl_id, 1 AS hops,
         ARRAY[old_pdl_id, current_pdl_id] AS visited
  FROM   {{ source('catalog', 'pdl_id_aliases') }}

  UNION ALL

  SELECT w.old_pdl_id, a.current_pdl_id, w.hops + 1,
         w.visited || a.current_pdl_id
  FROM   walk w
  JOIN   {{ source('catalog', 'pdl_id_aliases') }} a
    ON   a.old_pdl_id = w.current_pdl_id
  WHERE  w.hops < 10
    AND  NOT (a.current_pdl_id = ANY(w.visited))
)

SELECT old_pdl_id,
       MAX(hops) AS max_hops_reached
FROM   walk
GROUP  BY old_pdl_id
HAVING MAX(hops) = 10
