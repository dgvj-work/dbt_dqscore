{#- ============================================================
    Relational / referential tests
   ============================================================ -#}


{#- A tolerant `relationships` test: passes when at least `at_least` (0..1)
    of non-null child values exist in the parent.
    Usage:
      - dbt_dqscore.relationship_proportion:
          to: ref('dim_customers')
          field: customer_id
          at_least: 0.99                                       -#}
{% test relationship_proportion(model, column_name, to, field, at_least=1.0) %}

with parent as (

    select distinct {{ field }} as parent_id
    from {{ to }}

),

child as (

    select {{ column_name }} as child_id
    from {{ model }}
    where {{ column_name }} is not null

),

stats as (

    select
        count(*) as total_records,
        sum(case when p.parent_id is null then 0 else 1 end) as matched_records

    from child c
    left join parent p
        on c.child_id = p.parent_id

)

select
    total_records,
    matched_records,
    matched_records * 1.0 / nullif(total_records, 0) as match_proportion

from stats
where matched_records * 1.0 / nullif(total_records, 0) < {{ at_least }}

{% endtest %}


{#- Fails when distinct-value counts differ between two columns/relations.
    Catches fan-out or dropped dimensions after joins. -#}
{% test cardinality_equal(model, column_name, to, field) %}

with a as (

    select count(distinct {{ column_name }}) as distinct_count
    from {{ model }}

),

b as (

    select count(distinct {{ field }}) as distinct_count
    from {{ to }}

)

select
    a.distinct_count as model_distinct_count,
    b.distinct_count as compare_distinct_count

from a
cross join b
where a.distinct_count != b.distinct_count

{% endtest %}
