{{ config(severity='warn') }}

-- Singular test: surface any duplicate company_pdl_id in
-- staging.pdl_person_companies_unique with full provenance for debugging.
--
-- severity='warn' — fires as a dbt warning but does NOT fail the build.
-- The generic `unique` test on company_pdl_id (schema.yml) is the actual
-- gate; if violations exist, that test fails first with error severity.
-- This singular test is a DEBUGGING AID: it returns the offending
-- company_pdl_id along with the duplicate count and the partition_ids /
-- loaded_ats of each colliding row, so an operator investigating a unique
-- failure can immediately see WHERE the conflict came from without writing
-- the diagnostic query manually.
--
-- Parallel to pdl_person_unique_alias_cycle_guard.sql in pattern + intent
-- (surface-the-violator, don't block-the-build).
--
-- Returns zero rows under normal conditions.

SELECT
    company_pdl_id,
    COUNT(*)                                          AS dup_count,
    ARRAY_AGG(partition_id ORDER BY loaded_at DESC)   AS partition_ids,
    ARRAY_AGG(loaded_at    ORDER BY loaded_at DESC)   AS loaded_ats
FROM {{ ref('pdl_person_companies_unique') }}
GROUP BY company_pdl_id
HAVING COUNT(*) > 1
