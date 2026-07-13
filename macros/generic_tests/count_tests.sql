{#- ============================================================
    Count / volume tests (table-level unless noted)
   ============================================================ -#}


{#- Fails when total row count is outside [min_value, max_value]. -#}
{% test row_count_between(model, min_value=none, max_value=none) %}

with row_counts as (

    select count(*) as row_count from {{ model }}

)

select row_count
from row_counts
where 1 = 0
{% if min_value is not none %} or row_count < {{ min_value }} {% endif %}
{% if max_value is not none %} or row_count > {{ max_value }} {% endif %}

{% endtest %}


{#- Fails when total row count differs from an exact expected value. -#}
{% test row_count_equal(model, value) %}

with row_counts as (

    select count(*) as row_count from {{ model }}

)

select row_count
from row_counts
where row_count != {{ value }}

{% endtest %}


{#- Fails when this model's row count differs from another model's.
    Usage: compare_model: ref('stg_orders')  -#}
{% test equal_row_count(model, compare_model) %}

with a as (

    select count(*) as row_count from {{ model }}

),

b as (

    select count(*) as row_count from {{ compare_model }}

)

select
    a.row_count as model_row_count,
    b.row_count as compare_row_count

from a
cross join b
where a.row_count != b.row_count

{% endtest %}


{#- Fails when model_rows / compare_rows falls outside [min_ratio, max_ratio].
    Useful for "staging should keep >= 95% of raw rows" style checks. -#}
{% test row_count_ratio(model, compare_model, min_ratio=none, max_ratio=none) %}

with a as (

    select count(*) as row_count from {{ model }}

),

b as (

    select count(*) as row_count from {{ compare_model }}

),

ratio as (

    select
        a.row_count as model_row_count,
        b.row_count as compare_row_count,
        a.row_count * 1.0 / nullif(b.row_count, 0) as row_count_ratio
    from a
    cross join b

)

select *
from ratio
where 1 = 0
{% if min_ratio is not none %} or row_count_ratio < {{ min_ratio }} {% endif %}
{% if max_ratio is not none %} or row_count_ratio > {{ max_ratio }} {% endif %}

{% endtest %}


{#- Column-level: fails when the number of distinct values is outside bounds. -#}
{% test distinct_count_between(model, column_name, min_value=none, max_value=none) %}

with distinct_counts as (

    select count(distinct {{ column_name }}) as distinct_count
    from {{ model }}

)

select distinct_count
from distinct_counts
where 1 = 0
{% if min_value is not none %} or distinct_count < {{ min_value }} {% endif %}
{% if max_value is not none %} or distinct_count > {{ max_value }} {% endif %}

{% endtest %}


{#- Column-level: fails when the share of rows equal to `value` is outside bounds.
    e.g. status = 'cancelled' should be under 10% of orders. -#}
{% test value_share(model, column_name, value, min_share=none, max_share=none, quote=true) %}

with shares as (

    select
        sum(case when {{ column_name }} = {% if quote %}'{{ value | replace("'", "''") }}'{% else %}{{ value }}{% endif %}
            then 1 else 0 end) * 1.0
            / nullif(count(*), 0) as value_share

    from {{ model }}

)

select value_share
from shares
where 1 = 0
{% if min_share is not none %} or value_share < {{ min_share }} {% endif %}
{% if max_share is not none %} or value_share > {{ max_share }} {% endif %}

{% endtest %}


{#- Table-level: fails when the relation's column count differs from `value`.
    Catches accidental schema drift in sources. -#}
{% test column_count_equal(model, value) %}

{%- if execute -%}
    {%- set actual = adapter.get_columns_in_relation(model) | length -%}
{%- else -%}
    {%- set actual = 0 -%}
{%- endif -%}

select {{ actual }} as actual_column_count
where {{ actual }} != {{ value }}

{% endtest %}
