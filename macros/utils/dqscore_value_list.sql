{#- Renders a comma-separated SQL value list, optionally quoted.
    Single quotes inside quoted values are escaped for SQL safety. -#}
{% macro dqscore_value_list(values, quote=true) %}
    {%- for v in values -%}
        {%- if quote -%}'{{ v | replace("'", "''") }}'{%- else -%}{{ v }}{%- endif -%}
        {%- if not loop.last -%}, {% endif -%}
    {%- endfor -%}
{% endmacro %}
