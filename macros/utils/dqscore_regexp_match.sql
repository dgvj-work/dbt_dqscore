{#-
    Cross-database regex predicate. Returns a boolean SQL expression that is
    true when `column` matches `pattern`.

    Tip for portable patterns: prefer character classes over backslash
    escapes (e.g. `[.]` instead of `\.`) so the same pattern works on
    Snowflake, BigQuery, Postgres, Redshift, Databricks and DuckDB.
-#}

{% macro dqscore_regexp_match(column, pattern) %}
    {{ return(adapter.dispatch('dqscore_regexp_match', 'dbt_dqscore')(column, pattern)) }}
{% endmacro %}

{%- macro _dqscore_safe_pattern(pattern) -%}
{{- pattern | replace("'", "''") -}}
{%- endmacro -%}

{% macro default__dqscore_regexp_match(column, pattern) %}
    {{ column }} ~ '{{ dbt_dqscore._dqscore_safe_pattern(pattern) }}'
{% endmacro %}

{% macro snowflake__dqscore_regexp_match(column, pattern) %}
    regexp_like({{ column }}, '{{ dbt_dqscore._dqscore_safe_pattern(pattern) }}')
{% endmacro %}

{% macro bigquery__dqscore_regexp_match(column, pattern) %}
    regexp_contains({{ column }}, r'{{ dbt_dqscore._dqscore_safe_pattern(pattern) }}')
{% endmacro %}

{% macro redshift__dqscore_regexp_match(column, pattern) %}
    {{ column }} ~ '{{ dbt_dqscore._dqscore_safe_pattern(pattern) }}'
{% endmacro %}

{% macro spark__dqscore_regexp_match(column, pattern) %}
    {{ column }} rlike '{{ dbt_dqscore._dqscore_safe_pattern(pattern) }}'
{% endmacro %}

{% macro databricks__dqscore_regexp_match(column, pattern) %}
    {{ column }} rlike '{{ dbt_dqscore._dqscore_safe_pattern(pattern) }}'
{% endmacro %}

{% macro duckdb__dqscore_regexp_match(column, pattern) %}
    regexp_matches({{ column }}, '{{ dbt_dqscore._dqscore_safe_pattern(pattern) }}')
{% endmacro %}
