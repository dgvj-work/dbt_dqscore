-- Assert the scoring hook wrote a run summary for the previous invocation.
-- Run AFTER `dbt test --exclude tag:assert_scoring` so score tables exist.
-- Selected in CI via: dbt test --select tag:assert_scoring

{{ config(tags=['assert_scoring']) }}

with latest as (

    select *
    from {{ target.schema }}.dqscore_run_summary
    order by run_completed_at desc
    limit 1

)

select
    'missing or empty dqscore_run_summary' as error
from latest
where total_tests is null
   or total_tests < 1
   or quality_score is null
   or quality_score < 0
   or quality_score > 100

union all

select
    'quality_score outside expected integration band (90-100)' as error
from latest
where quality_score < 90
   or quality_score > 100

union all

select
    'expected at least one warn status in the clean seed suite' as error
from latest
where warned < 1
