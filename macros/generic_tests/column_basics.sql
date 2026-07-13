{#- ============================================================
    Column-level basics
    Usage in schema.yml:  dbt_dqscore.<test_name>
   ============================================================ -#}


{#- Passes when at least `at_least` (0..1) of rows are non-null. -#}
{% test not_null_proportion(model, column_name, at_least=1.0) %}

with validation as (

    select
        sum(case when {{ column_name }} is null then 0 else 1 end) * 1.0
            / nullif(count(*), 0) as not_null_proportion

    from {{ model }}

)

select not_null_proportion
from validation
where not_null_proportion < {{ at_least }}

{% endtest %}


{#- Fails rows outside [min_value, max_value]. Nulls pass (pair with not_null). -#}
{% test in_range(model, column_name, min_value=none, max_value=none, inclusive=true) %}

{%- set min_op = '<' if inclusive else '<=' -%}
{%- set max_op = '>' if inclusive else '>=' -%}

select {{ column_name }}
from {{ model }}
where {{ column_name }} is not null
  and (
        1 = 0
        {% if min_value is not none %} or {{ column_name }} {{ min_op }} {{ min_value }} {% endif %}
        {% if max_value is not none %} or {{ column_name }} {{ max_op }} {{ max_value }} {% endif %}
  )

{% endtest %}


{#- Fails rows whose value is not in the allowed set. Nulls pass. -#}
{% test in_set(model, column_name, values, quote=true) %}

select {{ column_name }}
from {{ model }}
where {{ column_name }} is not null
  and {{ column_name }} not in ({{ dbt_dqscore.dqscore_value_list(values, quote) }})

{% endtest %}


{#- Fails rows whose value IS in the forbidden set. -#}
{% test not_in_set(model, column_name, values, quote=true) %}

select {{ column_name }}
from {{ model }}
where {{ column_name }} is not null
  and {{ column_name }} in ({{ dbt_dqscore.dqscore_value_list(values, quote) }})

{% endtest %}


{#- Fails when the column has one (or zero) distinct values across a non-empty table. -#}
{% test not_constant(model, column_name, group_by=none) %}

select
    {% if group_by %}{{ group_by | join(', ') }},{% endif %}
    count(distinct {{ column_name }}) as distinct_values

from {{ model }}
{% if group_by %}group by {{ group_by | join(', ') }}{% endif %}
having count(*) > 0
   and count(distinct {{ column_name }}) <= 1

{% endtest %}


{#- Fails rows where a free-form SQL expression is not true.
    Null expression results fail (unknown is not true). -#}
{% test expression_is_true(model, expression) %}

select *
from {{ model }}
where not ({{ expression }})
   or ({{ expression }}) is null

{% endtest %}


{#- Fails rows where left_column and right_column violate `operator`
    (one of <, <=, >, >=, =, !=). Nulls on either side pass. -#}
{% test column_pair_compare(model, left_column, right_column, operator='<=') %}

{%- set allowed = ['<', '<=', '>', '>=', '=', '!=', '<>'] -%}
{%- if operator not in allowed -%}
    {{ exceptions.raise_compiler_error("dbt_dqscore.column_pair_compare: operator must be one of " ~ allowed | join(', ')) }}
{%- endif -%}

select
    {{ left_column }} as left_value,
    {{ right_column }} as right_value
from {{ model }}
where {{ left_column }} is not null
  and {{ right_column }} is not null
  and not ({{ left_column }} {{ operator }} {{ right_column }})

{% endtest %}
