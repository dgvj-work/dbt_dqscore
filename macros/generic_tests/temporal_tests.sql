{#- ============================================================
    Temporal / freshness tests
   ============================================================ -#}


{#- Fails when max(column) is older than `interval` dateparts ago (or table is empty).
    e.g. datepart='day', interval=1  ->  data must be at most 1 day old. -#}
{% test recency(model, column_name, datepart='day', interval=1) %}

{%- set neg_interval = 0 - interval -%}

with latest as (

    select max({{ column_name }}) as most_recent
    from {{ model }}

)

select most_recent
from latest
where most_recent is null
   or most_recent < {{ dbt.dateadd(datepart, neg_interval, dbt.current_timestamp()) }}

{% endtest %}


{#- Fails rows with timestamps/dates in the future. -#}
{% test no_future_dates(model, column_name) %}

select {{ column_name }}
from {{ model }}
where {{ column_name }} is not null
  and {{ column_name }} > {{ dbt.current_timestamp() }}

{% endtest %}


{#- Fails when consecutive distinct dates are more than `max_gap` dateparts apart.
    Catches missing days/weeks in event or snapshot tables. -#}
{% test no_date_gaps(model, column_name, datepart='day', max_gap=1) %}

with distinct_dates as (

    select distinct {{ column_name }} as date_value
    from {{ model }}
    where {{ column_name }} is not null

),

with_next as (

    select
        date_value,
        lead(date_value) over (order by date_value) as next_value

    from distinct_dates

)

select
    date_value,
    next_value,
    {{ dbt.datediff('date_value', 'next_value', datepart) }} as gap

from with_next
where next_value is not null
  and {{ dbt.datediff('date_value', 'next_value', datepart) }} > {{ max_gap }}

{% endtest %}
