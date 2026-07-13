-- Assert per-model scores and weighted/row-mode bookkeeping look right.

{{ config(tags=['assert_scoring']) }}

with latest_id as (

    select invocation_id
    from {{ target.schema }}.dqscore_run_summary
    order by run_completed_at desc
    limit 1

),

model_scores as (

    select m.*
    from {{ target.schema }}.dqscore_model_scores m
    inner join latest_id i using (invocation_id)

),

test_results as (

    select t.*
    from {{ target.schema }}.dqscore_test_results t
    inner join latest_id i using (invocation_id)

)

select
    'expected model scores for seed_customers and seed_orders' as error
where (
    select count(distinct model_name)
    from model_scores
    where model_name in ('seed_customers', 'seed_orders')
) < 2

union all

select
    'row-mode in_set warn should score 0.75 (2/8 failures)' as error
from test_results
where test_short_name = 'in_set'
  and status = 'warn'
  and (
        scoring_mode != 'row'
     or abs(test_score - 0.75) > 0.001
     or failures != 2
  )

union all

select
    'binary-mode value_share warn should score 0.5' as error
from test_results
where test_short_name = 'value_share'
  and status = 'warn'
  and (
        scoring_mode != 'binary'
     or abs(test_score - 0.5) > 0.001
  )

union all

select
    'dqscore_weight: 10 on unique_proportion was not applied' as error
from test_results
where test_short_name = 'unique_proportion'
  and abs(weight - 10) > 0.001
