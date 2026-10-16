{#-
  compose_location_input(city, state, country)

  Composes a (city, state, country) tuple into the single text string used as
  pdl_api.location_input_list.raw_input (the PDL location-cleaner queue). Any
  model that populates the queue and any model that joins cleaner results
  back to its source rows MUST both compose the key through this one macro,
  or the join misses. No model uses it yet; it is kept for the first
  location-cleaner consumer.

  - NULLIF(TRIM(...), '') inside CONCAT_WS skips empty components (a row with
    only city composes as "Chicago", not "Chicago, , ").
  - The outer NULLIF(..., '') yields NULL for the all-empty case, so those rows
    never hit the queue.
  - No LOWER() here: callers are expected to pass already-normalized values.
-#}
{% macro compose_location_input(city, state, country) %}
    NULLIF(
        CONCAT_WS(
            ', ',
            NULLIF(TRIM({{ city }}), ''),
            NULLIF(TRIM({{ state }}), ''),
            NULLIF(TRIM({{ country }}), '')
        ),
        ''
    )
{% endmacro %}
