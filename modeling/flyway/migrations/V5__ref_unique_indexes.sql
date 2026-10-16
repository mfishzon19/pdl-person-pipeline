-- =============================================================================
-- V5__ref_unique_indexes.sql — COALESCE-based UNIQUE indexes on ref.city
-- and ref.location.
--
-- HAND-AUTHORED. DBML cannot express COALESCE(...) inside a UNIQUE constraint
-- (the unique-with-nullable-FK-coalesce-to-sentinel pattern). These indexes
-- have to be created after V4 (which creates the ref.* tables).
--
-- Why COALESCE-to-0 instead of plain composite UNIQUE: Postgres treats NULL
-- as distinct in UNIQUE constraints by default. Without coalescing, two rows
-- with the same country and NULL state_province would both be inserted as
-- distinct rows. The 0 sentinel works because ids start at 1 and never
-- collide (IDENTITY ids here; since V14, dbt-computed ROW_NUMBER ids, which
-- also start at 1).
--
-- Doc references:
--   - docs/data_model/12_location.md §4.4 (ref.city UNIQUE rationale)
--   - docs/data_model/12_location.md §4.6 (ref.location UNIQUE rationale)
-- =============================================================================

CREATE UNIQUE INDEX city_country_state_province_name_lc_uk
    ON ref.city (country_id, COALESCE(state_province_id, 0), name_lc);

CREATE UNIQUE INDEX location_country_state_province_city_metro_uk
    ON ref.location (
        country_id,
        COALESCE(state_province_id, 0),
        COALESCE(city_id, 0),
        COALESCE(metro_id, 0)
    );
