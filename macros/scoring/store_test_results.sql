{#- ============================================================
    dqscore scoring engine
    ------------------------------------------------------------
    Captures every test result at the end of a run and computes
    row-weighted, importance-weighted 0-100 quality scores:
      - per test        (dqscore_test_results)
      - per model       (dqscore_model_scores)
      - per invocation  (dqscore_run_summary)

    Works with ANY tests: dbt built-ins, dbt-expectations,
    dbt-utils, dbt_dqscore, and your custom generic tests.

    Setup (dbt_project.yml):

      on-run-end:
        - "{{ dbt_dqscore.store_test_results(results) }}"

    Optional configuration (dbt_project.yml):

      vars:
        dqscore:
          enabled: true          # kill switch
          default_weight: 1      # weight when a test declares none
          retention_days: 30     # delete stored rows older than this
          schema: data_quality   # write score tables to a dedicated schema
          fail_below: 95         # fail the invocation if score < threshold
          row_level_tests: []    # extra test names to score by failing-row share
          binary_tests: []       # test names to force pass/fail scoring

    Per-test overrides (schema.yml):

      tests:
        - unique:
            config:
              meta:
                dqscore_weight: 10     # importance weight
                dqscore_mode: binary   # or: row
                dqscore_exclude: true  # store but do not score

    Scoring model:
      - "row" mode  : test_score = 1 - (failing rows / model rows), clamped to [0,1]
      - "binary"    : pass = 1.0, warn = 0.5, fail = 0.0
      - error       : 0.0 ; skipped tests are stored but excluded from scores
      - model/run score = 100 * sum(weight * test_score) / sum(weight)
   ============================================================ -#}

{% macro store_test_results(results, results_table='dqscore_test_results', summary_table='dqscore_run_summary', model_scores_table='dqscore_model_scores') %}
    {{ return(adapter.dispatch('store_test_results', 'dbt_dqscore')(results, results_table, summary_table, model_scores_table)) }}
{% endmacro %}

{% macro default__store_test_results(results, results_table, summary_table, model_scores_table) %}

{% if execute %}

{%- set cfg = var('dqscore', {}) -%}
{%- if cfg.get('enabled', true) -%}

    {%- set default_weight = cfg.get('default_weight', 1) -%}
    {%- set retention_days = cfg.get('retention_days', none) -%}
    {%- set fail_below = cfg.get('fail_below', none) -%}

    {#- tests whose failure rows are counted against the model's row count -#}
    {%- set row_level_defaults = [
        'not_null', 'unique', 'accepted_values', 'relationships',
        'in_range', 'in_set', 'not_in_set', 'matches_regex', 'string_length',
        'not_empty_string', 'no_leading_trailing_whitespace', 'parses_as_numeric',
        'valid_email', 'no_future_dates', 'no_outliers_zscore',
        'monotonically_increasing', 'sequential_values', 'no_date_gaps',
        'no_duplicate_rows', 'unique_combination',
        'expression_is_true', 'column_pair_compare', 'required_if'
    ] -%}
    {%- set row_level_tests = row_level_defaults + cfg.get('row_level_tests', []) -%}
    {%- set binary_overrides = cfg.get('binary_tests', []) -%}

    {%- set tests = [] -%}
    {%- for res in results -%}
        {%- if res.node.resource_type | string == 'test' -%}
            {%- do tests.append(res) -%}
        {%- endif -%}
    {%- endfor -%}

    {%- if tests | length > 0 -%}

        {#- ------------------------------------------------------------
            1. Resolve which model/seed/source each test is attached to
           ------------------------------------------------------------ -#}
        {%- set records = [] -%}
        {%- set uid_set = [] -%}

        {%- for res in tests -%}
            {%- set node = res.node -%}
            {%- set found = namespace(uid=none) -%}
            {%- if node.attached_node -%}
                {%- set found.uid = node.attached_node -%}
            {%- else -%}
                {%- for dep in node.depends_on.nodes -%}
                    {%- if found.uid is none and (dep.startswith('model.') or dep.startswith('seed.') or dep.startswith('snapshot.') or dep.startswith('source.')) -%}
                        {%- set found.uid = dep -%}
                    {%- endif -%}
                {%- endfor -%}
            {%- endif -%}
            {%- do records.append({'res': res, 'uid': found.uid}) -%}
            {%- if found.uid is not none and found.uid not in uid_set -%}
                {%- do uid_set.append(found.uid) -%}
            {%- endif -%}
        {%- endfor -%}

        {#- ------------------------------------------------------------
            2. Fetch row counts for tested relations (batched queries)
           ------------------------------------------------------------ -#}
        {%- set count_entries = [] -%}
        {%- set uid_names = {} -%}
        {%- for uid in uid_set -%}
            {%- set gnode = graph.nodes.get(uid) or graph.sources.get(uid) -%}
            {%- if gnode -%}
                {%- set ident = gnode.get('alias') or gnode.get('identifier') or gnode.get('name') -%}
                {%- do uid_names.update({uid: gnode.get('name')}) -%}
                {%- set rel = adapter.get_relation(gnode.get('database'), gnode.get('schema'), ident) -%}
                {%- if rel is not none -%}
                    {%- do count_entries.append([uid, rel | string]) -%}
                {%- endif -%}
            {%- endif -%}
        {%- endfor -%}

        {%- set count_map = {} -%}
        {%- for chunk in count_entries | batch(25) -%}
            {%- set parts = [] -%}
            {%- for e in chunk -%}
                {%- do parts.append("select cast('" ~ e[0] ~ "' as " ~ dbt.type_string() ~ ") as uid, count(*) as n from " ~ e[1]) -%}
            {%- endfor -%}
            {%- set count_result = run_query(parts | join(' union all ')) -%}
            {%- for r in count_result.rows -%}
                {%- do count_map.update({r[0]: r[1]}) -%}
            {%- endfor -%}
        {%- endfor -%}

        {#- ------------------------------------------------------------
            3. Score every test
           ------------------------------------------------------------ -#}
        {%- set scored = [] -%}
        {%- set tally = namespace(passed=0, warned=0, failed=0, errored=0, skipped=0) -%}

        {%- for rec in records -%}
            {%- set res = rec['res'] -%}
            {%- set node = res.node -%}
            {%- set status = res.status | string | lower -%}

            {%- if node.test_metadata -%}
                {%- set short_name = node.test_metadata.name -%}
            {%- else -%}
                {%- set short_name = node.name -%}
            {%- endif -%}

            {%- set meta = node.config.meta or {} -%}
            {%- set weight = meta.get('dqscore_weight', default_weight) -%}
            {%- set excluded = meta.get('dqscore_exclude', false) -%}

            {%- set mode_override = meta.get('dqscore_mode') -%}
            {%- if excluded -%}
                {%- set mode = 'excluded' -%}
            {%- elif mode_override -%}
                {%- set mode = mode_override -%}
            {%- elif short_name in binary_overrides -%}
                {%- set mode = 'binary' -%}
            {%- elif short_name in row_level_tests or 'expect_column_values' in short_name -%}
                {%- set mode = 'row' -%}
            {%- else -%}
                {%- set mode = 'binary' -%}
            {%- endif -%}

            {%- set failures = res.failures if res.failures is not none else 0 -%}
            {%- set model_rows = count_map.get(rec['uid']) -%}

            {%- set calc = namespace(rate=none, score=none, is_skipped=false) -%}

            {%- if status == 'skipped' or excluded -%}
                {%- set calc.is_skipped = true -%}
                {%- if status == 'skipped' -%}
                    {%- set tally.skipped = tally.skipped + 1 -%}
                {%- elif status == 'pass' -%}
                    {%- set tally.passed = tally.passed + 1 -%}
                {%- elif status == 'warn' -%}
                    {%- set tally.warned = tally.warned + 1 -%}
                {%- elif status == 'error' -%}
                    {%- set tally.errored = tally.errored + 1 -%}
                {%- else -%}
                    {%- set tally.failed = tally.failed + 1 -%}
                {%- endif -%}
            {%- elif status == 'error' -%}
                {%- set calc.score = 0.0 -%}
                {%- set tally.errored = tally.errored + 1 -%}
            {%- else -%}
                {%- if status == 'pass' -%}
                    {%- set tally.passed = tally.passed + 1 -%}
                {%- elif status == 'warn' -%}
                    {%- set tally.warned = tally.warned + 1 -%}
                {%- else -%}
                    {%- set tally.failed = tally.failed + 1 -%}
                {%- endif -%}

                {%- if mode == 'row' and model_rows is not none and model_rows > 0 -%}
                    {%- set raw_rate = failures * 1.0 / model_rows -%}
                    {%- set calc.rate = (1.0 if raw_rate > 1 else raw_rate) | round(6) -%}
                    {%- set calc.score = (1.0 - calc.rate) | round(4) -%}
                {%- else -%}
                    {%- if status == 'pass' -%}
                        {%- set calc.score = 1.0 -%}
                    {%- elif status == 'warn' -%}
                        {%- set calc.score = 0.5 -%}
                    {%- else -%}
                        {%- set calc.score = 0.0 -%}
                    {%- endif -%}
                {%- endif -%}
            {%- endif -%}

            {%- do scored.append({
                'uid': rec['uid'],
                'model_name': uid_names.get(rec['uid'], 'unknown'),
                'test_name': node.name,
                'short_name': short_name,
                'status': status,
                'mode': ('excluded' if excluded else (mode if not calc.is_skipped else 'skipped')),
                'failures': failures,
                'model_rows': model_rows,
                'rate': calc.rate,
                'weight': weight,
                'score': calc.score,
                'points': (weight * calc.score) if calc.score is not none else 0,
                'skipped': calc.is_skipped,
                'exec_time': res.execution_time if res.execution_time is not none else 0
            }) -%}
        {%- endfor -%}

        {#- ------------------------------------------------------------
            4. Create tables, apply retention, delete this invocation
               (idempotent on rerun), insert
           ------------------------------------------------------------ -#}
        {%- set dq_schema = cfg.get('schema', target.schema) -%}
        {%- if dq_schema != target.schema -%}
            {%- do run_query('create schema if not exists ' ~ dq_schema) -%}
        {%- endif -%}
        {%- set results_relation = dq_schema ~ '.' ~ results_table -%}
        {%- set model_scores_relation = dq_schema ~ '.' ~ model_scores_table -%}
        {%- set summary_relation = dq_schema ~ '.' ~ summary_table -%}

        {%- do run_query('create table if not exists ' ~ results_relation ~ ' (
            invocation_id ' ~ dbt.type_string() ~ ',
            run_completed_at ' ~ dbt.type_timestamp() ~ ',
            model_name ' ~ dbt.type_string() ~ ',
            test_name ' ~ dbt.type_string() ~ ',
            test_short_name ' ~ dbt.type_string() ~ ',
            status ' ~ dbt.type_string() ~ ',
            scoring_mode ' ~ dbt.type_string() ~ ',
            failures ' ~ dbt.type_int() ~ ',
            model_row_count ' ~ dbt.type_int() ~ ',
            failure_rate ' ~ dbt.type_float() ~ ',
            weight ' ~ dbt.type_float() ~ ',
            test_score ' ~ dbt.type_float() ~ ',
            execution_time_seconds ' ~ dbt.type_float() ~ ')') -%}

        {%- do run_query('create table if not exists ' ~ model_scores_relation ~ ' (
            invocation_id ' ~ dbt.type_string() ~ ',
            run_completed_at ' ~ dbt.type_timestamp() ~ ',
            model_name ' ~ dbt.type_string() ~ ',
            total_tests ' ~ dbt.type_int() ~ ',
            quality_score ' ~ dbt.type_float() ~ ')') -%}

        {%- do run_query('create table if not exists ' ~ summary_relation ~ ' (
            invocation_id ' ~ dbt.type_string() ~ ',
            run_completed_at ' ~ dbt.type_timestamp() ~ ',
            total_tests ' ~ dbt.type_int() ~ ',
            passed ' ~ dbt.type_int() ~ ',
            warned ' ~ dbt.type_int() ~ ',
            failed ' ~ dbt.type_int() ~ ',
            errored ' ~ dbt.type_int() ~ ',
            skipped ' ~ dbt.type_int() ~ ',
            quality_score ' ~ dbt.type_float() ~ ')') -%}

        {%- if retention_days is not none -%}
            {%- set cutoff = dbt.dateadd('day', 0 - retention_days, dbt.current_timestamp()) -%}
            {%- do run_query('delete from ' ~ results_relation ~ ' where run_completed_at < ' ~ cutoff) -%}
            {%- do run_query('delete from ' ~ model_scores_relation ~ ' where run_completed_at < ' ~ cutoff) -%}
            {%- do run_query('delete from ' ~ summary_relation ~ ' where run_completed_at < ' ~ cutoff) -%}
        {%- endif -%}

        {%- do run_query("delete from " ~ results_relation ~ " where invocation_id = '" ~ invocation_id ~ "'") -%}
        {%- do run_query("delete from " ~ model_scores_relation ~ " where invocation_id = '" ~ invocation_id ~ "'") -%}
        {%- do run_query("delete from " ~ summary_relation ~ " where invocation_id = '" ~ invocation_id ~ "'") -%}

        {%- set value_rows = [] -%}
        {%- for s in scored -%}
            {%- set safe_test = s['test_name'] | replace("'", "''") -%}
            {%- set safe_model = s['model_name'] | replace("'", "''") -%}
            {%- do value_rows.append(
                "('" ~ invocation_id ~ "', " ~ dbt.current_timestamp() ~ ", '" ~ safe_model ~ "', '"
                ~ safe_test ~ "', '" ~ s['short_name'] | replace("'", "''") ~ "', '" ~ s['status'] ~ "', '"
                ~ s['mode'] ~ "', " ~ s['failures'] ~ ", "
                ~ (s['model_rows'] if s['model_rows'] is not none else 'null') ~ ", "
                ~ (s['rate'] if s['rate'] is not none else 'null') ~ ", "
                ~ s['weight'] ~ ", "
                ~ (s['score'] if s['score'] is not none else 'null') ~ ", "
                ~ s['exec_time'] ~ ")"
            ) -%}
        {%- endfor -%}
        {%- do run_query('insert into ' ~ results_relation ~ ' values ' ~ value_rows | join(', ')) -%}

        {#- per-model weighted scores -#}
        {%- set model_rows_sql = [] -%}
        {%- for uid in uid_set -%}
            {%- set recs = scored | selectattr('uid', 'equalto', uid) | rejectattr('skipped') | list -%}
            {%- if recs | length > 0 -%}
                {%- set wsum = recs | sum(attribute='weight') -%}
                {%- set psum = recs | sum(attribute='points') -%}
                {%- set mscore = (100.0 * psum / wsum) | round(2) if wsum > 0 else 100.0 -%}
                {%- set safe_model = uid_names.get(uid, 'unknown') | replace("'", "''") -%}
                {%- do model_rows_sql.append(
                    "('" ~ invocation_id ~ "', " ~ dbt.current_timestamp() ~ ", '" ~ safe_model ~ "', "
                    ~ recs | length ~ ", " ~ mscore ~ ")"
                ) -%}
            {%- endif -%}
        {%- endfor -%}
        {%- if model_rows_sql | length > 0 -%}
            {%- do run_query('insert into ' ~ model_scores_relation ~ ' values ' ~ model_rows_sql | join(', ')) -%}
        {%- endif -%}

        {#- overall weighted score -#}
        {%- set active = scored | rejectattr('skipped') | list -%}
        {%- set total_weight = active | sum(attribute='weight') -%}
        {%- set total_points = active | sum(attribute='points') -%}
        {%- if total_weight > 0 -%}
            {%- set overall = (100.0 * total_points / total_weight) | round(2) -%}
        {%- else -%}
            {%- set overall = 100.0 -%}
        {%- endif -%}

        {%- do run_query('insert into ' ~ summary_relation ~ ' values ' ~
            "('" ~ invocation_id ~ "', " ~ dbt.current_timestamp() ~ ", " ~ tests | length ~ ", "
            ~ tally.passed ~ ", " ~ tally.warned ~ ", " ~ tally.failed ~ ", "
            ~ tally.errored ~ ", " ~ tally.skipped ~ ", " ~ overall ~ ")") -%}

        {{ log("dqscore: quality score " ~ overall ~ "/100 (" ~ tally.passed ~ " passed, "
               ~ tally.warned ~ " warned, " ~ tally.failed ~ " failed, " ~ tally.errored
               ~ " errored, " ~ tally.skipped ~ " skipped)", info=true) }}

        {%- if fail_below is not none and overall < fail_below -%}
            {%- do exceptions.raise_compiler_error(
                "dqscore: quality score " ~ overall ~ " is below the required threshold of "
                ~ fail_below ~ ". See " ~ results_relation ~ " for the failing tests."
            ) -%}
        {%- endif -%}

    {%- endif -%}

{%- endif -%}

{% endif %}

{% endmacro %}
