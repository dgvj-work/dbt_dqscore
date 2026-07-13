{#- ============================================================
    Statistical tests
   ============================================================ -#}


{#- Fails when an aggregate of the column falls outside bounds.
    aggregation: one of avg | sum | min | max | stddev | count -#}
{% test aggregate_in_range(model, column_name, aggregation='avg', min_value=none, max_value=none) %}

{%- set allowed = ['avg', 'sum', 'min', 'max', 'stddev', 'count'] -%}
{%- if aggregation | lower not in allowed -%}
    {{ exceptions.raise_compiler_error("dbt_dqscore.aggregate_in_range: aggregation must be one of " ~ allowed | join(', ')) }}
{%- endif -%}

with calc as (

    select {{ aggregation }}({{ column_name }}) as aggregate_value
    from {{ model }}

)

select aggregate_value
from calc
where 1 = 0
{% if min_value is not none %} or aggregate_value < {{ min_value }} {% endif %}
{% if max_value is not none %} or aggregate_value > {{ max_value }} {% endif %}

{% endtest %}


{#- Fails rows whose z-score exceeds `sigma` standard deviations from the mean. -#}
{% test no_outliers_zscore(model, column_name, sigma=3.0) %}

with stats as (

    select
        avg({{ column_name }}) as mean_value,
        stddev({{ column_name }}) as stddev_value

    from {{ model }}
    where {{ column_name }} is not null

)

select
    m.{{ column_name }},
    s.mean_value,
    s.stddev_value,
    abs(m.{{ column_name }} - s.mean_value) / s.stddev_value as z_score

from {{ model }} m
cross join stats s
where m.{{ column_name }} is not null
  and s.stddev_value > 0
  and abs(m.{{ column_name }} - s.mean_value) / s.stddev_value > {{ sigma }}

{% endtest %}


{#- Fails when values decrease along `sort_column` order.
    strictly=true also fails on ties. Optional group_by (list). -#}
{% test monotonically_increasing(model, column_name, sort_column=none, strictly=false, group_by=none) %}

{%- set sort_col = sort_column if sort_column else column_name -%}
{%- set op = '<=' if strictly else '<' -%}

with lagged as (

    select
        {{ column_name }} as current_value,
        lag({{ column_name }}) over (
            {% if group_by %}partition by {{ group_by | join(', ') }}{% endif %}
            order by {{ sort_col }}
        ) as previous_value

    from {{ model }}

)

select current_value, previous_value
from lagged
where previous_value is not null
  and current_value {{ op }} previous_value

{% endtest %}


{#- Fails when consecutive values (ordered by the column) do not step by `interval`.
    Great for gap-free surrogate keys or invoice numbers. Optional group_by (list). -#}
{% test sequential_values(model, column_name, interval=1, group_by=none) %}

with lagged as (

    select
        {{ column_name }} as current_value,
        lag({{ column_name }}) over (
            {% if group_by %}partition by {{ group_by | join(', ') }}{% endif %}
            order by {{ column_name }}
        ) as previous_value

    from {{ model }}

)

select current_value, previous_value
from lagged
where previous_value is not null
  and current_value - previous_value != {{ interval }}

{% endtest %}
