{#-
  staging.pdl_api_company_parsed — PDL Company Enrichment responses
  flattened into the typed column shape.

  Source: pdl_api.company_enrichment_call (append-only audit, one row per
  record in a bulk-enrichment response). Filtered to successful matches
  (response_status = 200) that carry a company id.

  Grain: one row per pdl_company_id. UNIQUE by API contract — each Company
  Enrichment call returns exactly one company response, so _parsed is 1:1
  with pdl_company_id (no _unique step — see docs/design/18_pdl_api_generic_caller.md
  §Dedup + provenance). The schema.yml unique test on pdl_company_id is the
  defensive guard if a duplicate ever appears (e.g. a future re-enrichment
  cycle), at which point a _unique step would be added.

  Simpler than pdl_person_experience_parsed: the enrichment response has no
  per-record array to unnest into rows — it's all top-level scalars plus a
  $.location sub-object flattened to scalars, plus 9 jsonb arrays/objects
  kept as-is (naics / sic / tags / alternative_names / alternative_domains /
  funding_stages / employee_count_by_country / profiles / affiliated_entities).
  integration reads them straight through as jsonb; ref.pdl_relationship +
  integration.company_affiliation unnest affiliated_entities[] downstream.

  immediate_parent / ultimate_parent are text scalars (the parent's
  pdl_company_id), NOT nested objects — resolved to integration.company.id
  in the integration model. See docs/data_model/08_company.md §7.

  Source-of-truth shape: modeling/dbml/staging.dbml block
  `staging.pdl_api_company_parsed`. DDL in V28__company_enrichment_schema.sql.
  on_schema_change='fail' enforces this SELECT matches the table.

  Materialization inherited from dbt_project.yml staging defaults:
    incremental + append + pre_hook=TRUNCATE ... RESTART IDENTITY CASCADE +
    on_schema_change='fail'.
-#}

SELECT
    r.id                        AS enrichment_call_id,
    r.bulk_batch_id,
    r.called_at,

    jt.pdl_company_id,

    -- Shared scalars (also emitted by person.experience.company)
    jt.name,
    jt.size,
    jt.founded,
    jt.industry,
    jt.type,
    jt.website,
    jt.linkedin_id,
    jt.linkedin_url,
    jt.facebook_url,
    jt.twitter_url,
    jt.ticker,

    -- Enrichment-only scalars
    jt.display_name,
    jt.linkedin_slug,
    jt.mic_exchange,
    jt.summary,
    jt.headline,
    jt.employee_count,
    jt.inferred_revenue,
    jt.immediate_parent,
    jt.ultimate_parent,
    jt.total_funding_raised,
    jt.latest_funding_stage,
    jt.last_funding_date,
    jt.number_funding_rounds,
    jt.dataset_version,
    jt.likelihood,

    -- Multi-valued enrichment fields kept as jsonb
    jt.naics,
    jt.sic,
    jt.tags,
    jt.alternative_names,
    jt.alternative_domains,
    jt.funding_stages,
    jt.employee_count_by_country,
    jt.profiles,
    jt.affiliated_entities,

    -- Location flattened from $.location (10-field object)
    jt.location_name,
    jt.location_locality,
    jt.location_region,
    jt.location_country,
    jt.location_continent,
    jt.location_metro,
    jt.location_postal_code,
    jt.location_street_address,
    jt.location_address_line_2,
    jt.location_geo
FROM {{ source('pdl_api', 'company_enrichment_call') }} r,
     JSON_TABLE(
       r.response_json,
       '$'
       COLUMNS (
         pdl_company_id            text          PATH '$.id',

         -- Shared scalars
         name                      text          PATH '$.name',
         size                      text          PATH '$.size',
         founded                   int4          PATH '$.founded',
         industry                  text          PATH '$.industry',
         type                      text          PATH '$.type',
         website                   text          PATH '$.website',
         linkedin_id               text          PATH '$.linkedin_id',
         linkedin_url              text          PATH '$.linkedin_url',
         facebook_url              text          PATH '$.facebook_url',
         twitter_url               text          PATH '$.twitter_url',
         ticker                    text          PATH '$.ticker',

         -- Enrichment-only scalars (immediate/ultimate_parent are text
         -- scalars — the parent's pdl_company_id, not nested objects)
         display_name              text          PATH '$.display_name',
         linkedin_slug             text          PATH '$.linkedin_slug',
         mic_exchange              text          PATH '$.mic_exchange',
         summary                   text          PATH '$.summary',
         headline                  text          PATH '$.headline',
         employee_count            int4          PATH '$.employee_count',
         inferred_revenue          text          PATH '$.inferred_revenue',
         immediate_parent          text          PATH '$.immediate_parent',
         ultimate_parent           text          PATH '$.ultimate_parent',
         total_funding_raised      bigint        PATH '$.total_funding_raised',
         latest_funding_stage      text          PATH '$.latest_funding_stage',
         last_funding_date         date          PATH '$.last_funding_date',
         number_funding_rounds     smallint      PATH '$.number_funding_rounds',
         dataset_version           text          PATH '$.dataset_version',
         likelihood                smallint      PATH '$.likelihood',

         -- Multi-valued enrichment (arrays/objects kept as jsonb)
         naics                     jsonb  FORMAT JSON PATH '$.naics',
         sic                       jsonb  FORMAT JSON PATH '$.sic',
         tags                      jsonb  FORMAT JSON PATH '$.tags',
         alternative_names         jsonb  FORMAT JSON PATH '$.alternative_names',
         alternative_domains       jsonb  FORMAT JSON PATH '$.alternative_domains',
         funding_stages            jsonb  FORMAT JSON PATH '$.funding_stages',
         employee_count_by_country jsonb  FORMAT JSON PATH '$.employee_count_by_country',
         profiles                  jsonb  FORMAT JSON PATH '$.profiles',
         affiliated_entities       jsonb  FORMAT JSON PATH '$.affiliated_entities',

         -- Location sub-object flattened to scalars
         location_name             text          PATH '$.location.name',
         location_locality         text          PATH '$.location.locality',
         location_region           text          PATH '$.location.region',
         location_country          text          PATH '$.location.country',
         location_continent        text          PATH '$.location.continent',
         location_metro            text          PATH '$.location.metro',
         location_postal_code      text          PATH '$.location.postal_code',
         location_street_address   text          PATH '$.location.street_address',
         location_address_line_2   text          PATH '$.location.address_line_2',
         location_geo              text          PATH '$.location.geo'
       )
     ) AS jt
WHERE r.response_status = 200
  AND jt.pdl_company_id IS NOT NULL
