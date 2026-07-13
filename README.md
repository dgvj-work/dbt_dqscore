# dbt_dqscore

[![CI](https://github.com/dgvj-work/dbt_dqscore/actions/workflows/ci.yml/badge.svg)](https://github.com/dgvj-work/dbt_dqscore/actions/workflows/ci.yml)
[![dbt versions](https://img.shields.io/badge/dbt-%3E%3D1.3%2C%3C3.0-orange)](https://docs.getdbt.com)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

A 0-100 data quality score for the dbt tests you already have. Row-weighted,
importance-weighted, per-model, with an optional CI quality gate. Works with
dbt built-in tests, dbt-utils, dbt-expectations, and custom tests.

Your dbt project runs hundreds of tests, and the output is a wall of PASS/FAIL.
`dbt_dqscore` turns that into a single number you can put on a dashboard, report
to stakeholders, track over time, and gate deployments on:

```
dqscore: quality score 98.33/100 (43 passed, 2 warned, 0 failed, 0 errored, 0 skipped)
```

Unlike naive pass-rate metrics, the score is:

- **Row-weighted.** A `not_null` test failing on 3 rows out of 10 million barely
  moves the score; failing on every row zeroes that test's contribution. The score
  reflects how much data is bad, not just how many tests are red.
- **Importance-weighted.** Declare that your primary-key test matters 10x more
  than a cosmetic range check in `schema.yml`.
- **Per-model.** A score for every model, seed, and source under test, plus a
  project-level rollup, written to your warehouse on every run.
- **CI gate.** Optionally fail the invocation when the score drops below a
  threshold, even if every individual test is only severity `warn`.

The package also includes 27 generic data quality tests for counts, statistics,
freshness, tolerant referential integrity, and free-form expressions.

## Installation

```yaml
# packages.yml
packages:
  - package: dgvj-work/dbt_dqscore
    version: [">=0.1.0", "<0.2.0"]
```

```
dbt deps
```

Until the package is on hub.getdbt.com, install from git (pin a tag, not a branch):

```yaml
packages:
  - git: "https://github.com/dgvj-work/dbt_dqscore.git"
    revision: 0.1.0
```

Compatibility: dbt Core and the dbt Fusion engine, `require-dbt-version: [">=1.3.0", "<3.0.0"]`.

## Setup

Add one line to your `dbt_project.yml`. No changes to your existing tests are
required:

```yaml
on-run-end:
  - "{{ dbt_dqscore.store_test_results(results) }}"
```

Every `dbt test` / `dbt build` now writes three tables:

| Table | Grain | What you get |
|---|---|---|
| `dqscore_run_summary` | one row per invocation | overall `quality_score`, counts by status |
| `dqscore_model_scores` | one row per model per invocation | per-model `quality_score` |
| `dqscore_test_results` | one row per test per invocation | status, failing rows, model row count, failure rate, weight, per-test score, execution time |

## How the score works

Each test receives a score in [0, 1]:

- **Row mode** (default for row-returning tests: `not_null`, `unique`,
  `relationships`, `accepted_values`, all `expect_column_values_*` tests from
  dbt-expectations, and dqscore's own row-level tests):
  `test_score = 1 - failing_rows / model_rows`, clamped to [0, 1].
- **Binary mode** (aggregate tests: row counts, averages, freshness):
  pass = 1.0, warn = 0.5, fail = 0.0.
- Errored tests score 0. Skipped tests and tests marked
  `meta.dqscore_exclude: true` are stored but excluded from scoring.

Then, per model and overall:

```
quality_score = 100 * sum(weight * test_score) / sum(weight)
```

Model row counts are fetched in batched queries (25 relations per query) at the
end of the run.

### Weighting the tests that matter

Works on any test, including native dbt tests you already have:

```yaml
columns:
  - name: order_id
    tests:
      - unique:
          config:
            meta:
              dqscore_weight: 10    # importance weight (default 1)
      - dbt_dqscore.in_range:
          min_value: 0
          config:
            meta:
              dqscore_weight: 2
              dqscore_mode: row     # or 'binary' to override auto-detection
```

Exclude a test from the KPI (still runs, still stored) with:

```yaml
- dbt_dqscore.valid_email:
    config:
      meta:
        dqscore_exclude: true
```

### Configuration

```yaml
# dbt_project.yml
vars:
  dqscore:
    enabled: true            # kill switch (e.g. disable in dev)
    default_weight: 1
    schema: data_quality     # write score tables to a dedicated schema
                             # (created if missing; defaults to target schema)
    retention_days: 30       # auto-delete stored results older than this
    fail_below: 95           # CI gate: fail the run when the score drops below
    row_level_tests: []      # extra test names to score in row mode
    binary_tests: []         # force specific test names to binary mode
```

Table names are also configurable:

```yaml
on-run-end:
  - "{{ dbt_dqscore.store_test_results(results, results_table='dq_results', summary_table='dq_summary', model_scores_table='dq_model_scores') }}"
```

**Quality gate.** With `fail_below` set, the invocation exits non-zero when the
overall score is under the threshold. Results are stored first, so the failing
run is still visible in your dashboards. This supports marking individual tests
`severity: warn` while still blocking when aggregate quality drops.

## Dashboard and reporting queries

Quality trend over time:

```sql
select run_completed_at, quality_score
from data_quality.dqscore_run_summary
order by run_completed_at
```

Worst models right now:

```sql
select model_name, quality_score
from data_quality.dqscore_model_scores
where invocation_id = (
    select invocation_id from data_quality.dqscore_run_summary
    order by run_completed_at desc limit 1
)
order by quality_score asc
```

Which tests are costing the most points:

```sql
select model_name, test_name, status, failures, failure_rate, weight, test_score
from data_quality.dqscore_test_results
where test_score < 1
order by weight * (1 - test_score) desc
```

## Using dqscore in an organisation

**Environments.** Scope scoring per target so dev noise does not pollute the trend:

```yaml
vars:
  dqscore:
    enabled: "{{ target.name == 'prod' }}"
    schema: data_quality
    retention_days: 90
```

**Permissions.** The hook needs, in the score schema only: `create table`,
`insert`, `delete`, and (if you use `schema:`) `create schema`. It also runs
`select count(*)` on tested relations. It never modifies your models, sources,
or seeds.

**Overhead.** One `count(*)` query per ~25 tested relations plus a handful of
small DML statements per invocation. Storage is bounded by `retention_days`;
writes are idempotent per `invocation_id`, so retried runs never double-count.

**Team-level SLOs.** Weights and the gate are plain yaml, so quality targets can
be code-reviewed like everything else.

**Audit trail.** `dqscore_test_results` keeps a per-invocation record of every
test, its failure counts, and timing.

### Comparison with Elementary

[Elementary](https://hub.getdbt.com/elementary-data/elementary/latest/) is a full
observability platform with anomaly detection, lineage, and a UI. `dbt_dqscore`
is a small scoring hook: one on-run-end macro, three tables, one number. The two
can coexist in the same project.

---

## Bundled tests

27 generic tests, referenced as `dbt_dqscore.<name>`. All support standard dbt
test configs (`severity`, `where`, `error_if`, ...). "Nulls pass" means null
values are ignored; pair with `not_null` to enforce presence.

On dbt 1.10.5+ / Fusion, nest test args under `arguments:` to avoid the
`MissingArgumentsPropertyInGenericTestDeprecation` warning. Top-level args still
work on dbt 1.3-1.11.

### Column basics

| Test | Fails when... | Key args |
|---|---|---|
| `not_null_proportion` | share of non-null rows < `at_least` | `at_least` (0-1) |
| `in_range` | value outside bounds (nulls pass) | `min_value`, `max_value`, `inclusive` |
| `in_set` | value not in allowed list (nulls pass) | `values`, `quote` |
| `not_in_set` | value in forbidden list | `values`, `quote` |
| `not_constant` | column has <= 1 distinct value in a non-empty table | `group_by` |
| `expression_is_true` | row where SQL `expression` is not true (nulls fail) | `expression` |
| `column_pair_compare` | `left_column` and `right_column` violate `operator` | `left_column`, `right_column`, `operator` |

### Strings

| Test | Fails when... | Key args |
|---|---|---|
| `matches_regex` | string doesn't match pattern (nulls pass) | `pattern` |
| `string_length` | length outside bounds | `min_len`, `max_len` |
| `not_empty_string` | value is `''` or whitespace-only | |
| `no_leading_trailing_whitespace` | `value != trim(value)` | |
| `parses_as_numeric` | string can't be read as a number | |
| `valid_email` | string doesn't look like an email | |

Regex runs through a cross-database dispatch macro (`dqscore_regexp_match`) with
implementations for Postgres, Snowflake, BigQuery, Redshift, Databricks/Spark and
DuckDB. Prefer character classes over backslash escapes (`[.]` not `\.`) for
portable patterns.

### Uniqueness and duplication

| Test | Fails when... | Key args |
|---|---|---|
| `unique_proportion` | share of distinct non-null values < `at_least` | `at_least` |
| `unique_combination` | a combination of columns repeats | `combination_of_columns` |
| `no_duplicate_rows` | fully duplicated rows exist (table-level) | `column_subset` (optional) |

### Counts and volume

| Test | Fails when... | Key args |
|---|---|---|
| `row_count_between` | row count outside bounds | `min_value`, `max_value` |
| `row_count_equal` | row count != exact value | `value` |
| `equal_row_count` | row count != another model's | `compare_model` |
| `row_count_ratio` | rows / compare-model rows outside bounds | `compare_model`, `min_ratio`, `max_ratio` |
| `distinct_count_between` | distinct values outside bounds | `min_value`, `max_value` |
| `value_share` | share of rows equal to `value` outside bounds | `value`, `min_share`, `max_share` |
| `column_count_equal` | relation's column count != expected (schema drift) | `value` |

### Statistical

| Test | Fails when... | Key args |
|---|---|---|
| `aggregate_in_range` | `avg`/`sum`/`min`/`max`/`stddev`/`count` outside bounds | `aggregation`, `min_value`, `max_value` |
| `no_outliers_zscore` | any row > `sigma` std devs from the mean | `sigma` |
| `monotonically_increasing` | values decrease along `sort_column` order | `sort_column`, `strictly`, `group_by` |
| `sequential_values` | consecutive values don't step by `interval` | `interval`, `group_by` |

### Temporal

| Test | Fails when... | Key args |
|---|---|---|
| `recency` | `max(column)` older than `interval` dateparts ago | `datepart`, `interval` |
| `no_future_dates` | any timestamp/date is in the future | |
| `no_date_gaps` | consecutive distinct dates more than `max_gap` apart | `datepart`, `max_gap` |

### Relational

| Test | Fails when... | Key args |
|---|---|---|
| `relationship_proportion` | FK match rate < `at_least` (tolerant `relationships`) | `to`, `field`, `at_least` |
| `cardinality_equal` | distinct counts differ between two relations | `to`, `field` |

Example: tolerate up to 1% orphaned keys instead of an all-or-nothing
`relationships` test:

```yaml
columns:
  - name: customer_id
    tests:
      - dbt_dqscore.relationship_proportion:
          to: ref('dim_customers')
          field: customer_id
          at_least: 0.99
```

`expression_is_true` / `column_pair_compare` examples:

```yaml
models:
  - name: fct_orders
    tests:
      - dbt_dqscore.expression_is_true:
          expression: "amount >= 0 and currency is not null"
      - dbt_dqscore.column_pair_compare:
          left_column: order_date
          right_column: ship_date
          operator: '<='
```

---

## Supported data warehouses

Built on dbt Core cross-database macros plus an adapter-dispatched regex macro.

| Adapter | Tests | Scoring hook | Notes |
|---|---|---|---|
| DuckDB | CI tested | CI tested | integration suite runs here |
| Postgres | expected | expected | |
| Snowflake | expected | expected | |
| BigQuery | expected | expected | `schema:` maps to a dataset |
| Redshift | expected | expected | |
| Databricks / Spark | expected | expected | |

"Expected" means the macros use dbt Core cross-database functions and dispatched
regex only. Adapter-specific CI runs are welcome.

## FAQ

**Does it work with tests from other packages?**
Yes. The scoring hook reads dbt's run results, so every test in the invocation
is scored regardless of origin. dbt-expectations `expect_column_values_*` tests
are auto-detected as row-level.

**What happens on `dbt build`?**
Models run first, then tests; the hook fires once at the end and scores the
tests. Seeds and snapshots under test are included.

**Grouped tests (`unique`, `accepted_values`) report fewer failures than
affected rows. Does that skew the score?**
Slightly, in the optimistic direction: dbt reports one failure per duplicated
value / rejected group, not per row. If that matters for a key test, set
`dqscore_mode: binary` on it.

**Can I score only some environments?**
Yes: `enabled: "{{ target.name == 'prod' }}"`.

**Does a failing quality gate hide my results?**
No. Results are stored before the gate raises.

**Can I keep a test out of the score?**
Yes: `config.meta.dqscore_exclude: true`.

## Integration tests

The suite runs clean seeds, bad-row seeds with inverted `error_if` checks, and
singular tests that assert score table contents and weighted math.

```
cd integration_tests
export DBT_PROFILES_DIR=.
dbt deps && dbt seed --full-refresh
dbt test --exclude tag:assert_scoring
dbt test --select tag:assert_scoring --vars '{dqscore: {enabled: false}}'
```

Requires `pip install dbt-duckdb`. CI runs this suite on every push.

## Publishing to dbt Hub

To list the package on [hub.getdbt.com](https://hub.getdbt.com), open a PR on
[dbt-labs/hubcap](https://github.com/dbt-labs/hubcap) adding
`dgvj-work/dbt_dqscore` to `hub.json`. Requirements:

1. Public GitHub repo with an open-source `LICENSE` (MIT).
2. Root `dbt_project.yml` with `name:` and `require-dbt-version`.
3. Semver GitHub releases/tags (`0.1.0` or `v0.1.0`, not `latest`).

After the hubcap PR merges, new releases are indexed automatically.

## Contributing

Issues and PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). Releases follow
semantic versioning.

## Also available for pandas

Checks plus a single quality score on DataFrames:
[dqscore on PyPI](https://pypi.org/project/dqscore/).

## License

[MIT](LICENSE)
