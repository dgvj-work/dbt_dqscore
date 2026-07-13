{#- ============================================================
    Uniqueness & duplication tests
   ============================================================ -#}


{#- Passes when at least `at_least` (0..1) of non-null values are distinct.
    Use at_least=1.0 for a strict-but-informative alternative to `unique`. -#}
{% test unique_proportion(model, column_name, at_least=1.0) %}

with validation as (

    select
        count(distinct {{ column_name }}) * 1.0
            / nullif(count({{ column_name }}), 0) as unique_proportion

    from {{ model }}

)

select unique_proportion
from validation
where unique_proportion < {{ at_least }}

{% endtest %}


{#- Fails when the combination of columns is not unique (composite key check). -#}
{% test unique_combination(model, combination_of_columns) %}

select
    {{ combination_of_columns | join(', ') }},
    count(*) as n_records

from {{ model }}
group by {{ combination_of_columns | join(', ') }}
having count(*) > 1

{% endtest %}


{#- Table-level: fails when fully duplicated rows exist.
    Pass `column_subset` to restrict the comparison to specific columns;
    otherwise all columns in the relation are used. -#}
{% test no_duplicate_rows(model, column_subset=none) %}

{%- if column_subset -%}
    {%- set cols = column_subset -%}
{%- elif execute -%}
    {%- set cols = adapter.get_columns_in_relation(model) | map(attribute='name') | list -%}
{%- else -%}
    {%- set cols = [] -%}
{%- endif -%}

{%- if cols | length == 0 -%}

select 1 as placeholder where 1 = 0

{%- else -%}

select
    {{ cols | join(', ') }},
    count(*) as n_records

from {{ model }}
group by {{ cols | join(', ') }}
having count(*) > 1

{%- endif -%}

{% endtest %}
