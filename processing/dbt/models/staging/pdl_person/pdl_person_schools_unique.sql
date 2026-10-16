{#-
  staging.pdl_person_schools_unique — dedup of pdl_person_schools_parsed
  by school_pdl_id. One row per unique school across all (person × education)
  source rows. Smaller universe than companies — most schools are shared
  across many persons.

  Filters NULL school_pdl_id (education entries PDL didn't link to a
  tracked school). Per-row provenance dropped at this layer for the same
  reason as companies_unique (canonical per-school row, not per-occurrence).

  Dedup ordering: loaded_at DESC, partition_id DESC.

  Source-of-truth: modeling/dbml/staging.dbml (10 columns).
-#}

SELECT DISTINCT ON (school_pdl_id)
    partition_id,
    loaded_at,
    school_pdl_id,
    school_name,
    school_type,
    school_domain,
    school_website,
    school_linkedin_url,
    school_linkedin_id,
    school_facebook_url,
    school_twitter_url
FROM {{ ref('pdl_person_schools_parsed') }}
WHERE school_pdl_id IS NOT NULL
ORDER BY school_pdl_id, loaded_at DESC, partition_id DESC
