{#- ============================================================
    String tests
   ============================================================ -#}


{#- Fails rows where the string does not match the regex. Nulls pass. -#}
{% test matches_regex(model, column_name, pattern) %}

select {{ column_name }}
from {{ model }}
where {{ column_name }} is not null
  and not ({{ dbt_dqscore.dqscore_regexp_match(column_name, pattern) }})

{% endtest %}


{#- Fails rows where string length is outside [min_len, max_len]. Nulls pass. -#}
{% test string_length(model, column_name, min_len=none, max_len=none) %}

select {{ column_name }}, {{ dbt.length(column_name) }} as string_length
from {{ model }}
where {{ column_name }} is not null
  and (
        1 = 0
        {% if min_len is not none %} or {{ dbt.length(column_name) }} < {{ min_len }} {% endif %}
        {% if max_len is not none %} or {{ dbt.length(column_name) }} > {{ max_len }} {% endif %}
  )

{% endtest %}


{#- Fails rows that are empty or whitespace-only strings. Nulls pass. -#}
{% test not_empty_string(model, column_name) %}

select {{ column_name }}
from {{ model }}
where {{ column_name }} is not null
  and trim({{ column_name }}) = ''

{% endtest %}


{#- Fails rows with leading or trailing whitespace. -#}
{% test no_leading_trailing_whitespace(model, column_name) %}

select {{ column_name }}
from {{ model }}
where {{ column_name }} is not null
  and {{ column_name }} != trim({{ column_name }})

{% endtest %}


{#- Fails string rows that cannot be parsed as a number (portable regex, no backslashes). -#}
{% test parses_as_numeric(model, column_name) %}

{%- set numeric_pattern = '^[-+]?[0-9]+([.][0-9]+)?$' -%}

select {{ column_name }}
from {{ model }}
where {{ column_name }} is not null
  and not ({{ dbt_dqscore.dqscore_regexp_match(column_name, numeric_pattern) }})

{% endtest %}


{#- Convenience: fails rows that do not look like an email address. -#}
{% test valid_email(model, column_name) %}

{%- set email_pattern = '^[^@ ]+@[^@ ]+[.][^@ ]+$' -%}

select {{ column_name }}
from {{ model }}
where {{ column_name }} is not null
  and not ({{ dbt_dqscore.dqscore_regexp_match(column_name, email_pattern) }})

{% endtest %}
