# dbt_dqscore

[![CI](https://github.com/dgvj-work/dbt_dqscore/actions/workflows/ci.yml/badge.svg)](https://github.com/dgvj-work/dbt_dqscore/actions/workflows/ci.yml)
[![dbt versions](https://img.shields.io/badge/dbt-%3E%3D1.3%2C%3C3.0-orange)](https://docs.getdbt.com)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> **A 0–100 data quality score for the dbt tests you already have.**
> Row-weighted, importance-weighted, per-model, with a CI quality gate —
> works with dbt built-in tests, dbt-utils, dbt-expectations, and any custom test.

Your dbt project runs hundreds of tests, and the output is a wall of PASS/FAIL.
`dbt_dqscore` turns that into a single number you can put on a dashboard, report
to stakeholders, track over time, and gate deployments on:

```
dqscore: quality score 98.33/100 (43 passed, 2 warned, 0 failed, 0 errored, 0 skipped)
```

Unlike naive pass-rate metrics, the score is:

- **Row-weighted** — a `not_null` test failing on 3 rows out of 10 million barely
  moves the score; failing on every row zeroes that test's contribution. The score
  reflects *how much* data is bad, not just how many tests are red.
- **Importance-weighted** — declare that your primary-key test matters 10x more
  than a cosmetic range check, right in your `schema.yml`.
- **Per-model** — a score for every model, seed, and source under test, plus a
  project-level rollup, written to your warehouse on every run.
- **A CI gate** — optionally fail the invocation when the score drops below a
  threshold, even if every individual test is only severity `warn`.

It also ships **27 generic data quality tests** (counts, statistics, freshness,
tolerant referential integrity, free-form expressions, and more) for gaps the
built-ins don't cover.

**Contents:** [Install](#installation) · [Setup](#two-minute-setup) ·
[Scoring](#how-the-score-works) · [Configuration](#configuration) ·
[Dashboards](#dashboard--reporting-queries) · [For teams](#using-dqscore-in-an-organisation) ·
[Bundled tests](#bundled-tests) · [Warehouses](#supported-data-warehouses) ·
[FAQ](#faq) · [Publishing to dbt Hub](#publishing-to-dbt-hub) · [Contributing](#contributing)

---

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

## Two-minute setup

Add one line to your `dbt_project.yml` — no changes to your existing tests needed:

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
  `test_score = 1 − failing_rows / model_rows`, clamped to [0, 1].
- **Binary mode** (aggregate tests: row counts, averages, freshness):
  pass = 1.0, warn = 0.5, fail = 0.0.
- Errored tests score 0. Skipped tests — and tests marked
  `meta.dqscore_exclude: true` — are stored but excluded from scoring.

Then, per model and overall:

```
quality_score = 100 × Σ(weight × test_score) / Σ(weight)
```

Model row counts are fetched in batched queries (25 relations per query) at the
end of the run.

### Weighting the tests that matter

Works on **any** test, including native dbt tests you already have:

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

**The quality gate.** With `fail_below` set, the invocation exits non-zero with a
clear message when the overall score is under the threshold — *after* results are
stored, so the failing run is still visible in your dashboards. This enables a
pattern most teams want but dbt doesn't natively support: mark individual tests
`severity: warn` (never block a deploy on one flaky check) while still blocking
when aggregate quality erodes.

## Dashboard & reporting queries

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

**Environments.** Scope scoring per target so dev noise doesn't pollute the trend:

```yaml
vars:
  dqscore:
    enabled: "{{ target.name == 'prod' }}"
    schema: data_quality
    retention_days: 90
```

**Permissions.** The hook needs, in the score schema only: `create table`,
`insert`, `delete`, and (if you use `schema:`) `create schema`. It additionally
runs `select count(*)` on tested relations. It never modifies your models,
sources, or seeds.

**Overhead.** One `count(*)` query per ~25 tested relations plus a handful of
small DML statements per invocation — typically a second or two. Storage is
bounded by `retention_days`; writes are idempotent per `invocation_id`, so
retried runs never double-count.

**Team-level SLOs.** Because weights and the gate are plain yaml, quality
targets are code-reviewed like everything else: platform teams can set
`fail_below` in CI profiles, domain teams can weight their contract-critical
columns, and the score becomes an auditable SLO rather than a vibe.

**Audit trail.** `dqscore_test_results` keeps a per-invocation record of every
test, its failure counts, and timing — useful for incident reviews and data
governance evidence without adopting a separate platform.

### How is this different from Elementary?

[Elementary](https://hub.getdbt.com/elementary-data/elementary/latest/) is a full
observability platform — anomaly detection, lineage, a UI. `dbt_dqscore` is
deliberately tiny: one hook, three tables, one number. If you want a KPI, a
trend line, and a CI gate without adopting a platform, this is the gap it fills.
The two can coexist in the same project.

---

## Bundled tests

27 generic tests, referenced as `dbt_dqscore.<name>`. All support standard dbt
test configs (`severity`, `where`, `error_if`, ...). "Nulls pass" means null
values are ignored — pair with `not_null` to enforce presence.

> **dbt ≥ 1.10.5 / Fusion tip:** nest test args under `arguments:` to silence the
> `MissingArgumentsPropertyInGenericTestDeprecation` warning. Top-level args still
> work on dbt 1.3–1.11.

### Column basics

| Test | Fails when... | Key args |
|---|---|---|
| `not_null_proportion` | share of non-null rows < `at_least` | `at_least` (0–1) |
| `in_range` | value outside bounds (nulls pass) | `min_value`, `max_value`, `inclusive` |
| `in_set` | value not in allowed list (nulls pass) | `values`, `quote` |
| `not_in_set` | value in forbidden list | `values`, `quote` |
| `not_constant` | column has ≤ 1 distinct value in a non-empty table | `group_by` |
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

### Uniqueness & duplication

| Test | Fails when... | Key args |
|---|---|---|
| `unique_proportion` | share of distinct non-null values < `at_least` | `at_least` |
| `unique_combination` | a combination of columns repeats | `combination_of_columns` |
| `no_duplicate_rows` | fully duplicated rows exist (table-level) | `column_subset` (optional) |

### Counts & volume

| Test | Fails when... | Key args |
|---|---|---|
| `row_count_between` | row count outside bounds | `min_value`, `max_value` |
| `row_count_equal` | row count ≠ exact value | `value` |
| `equal_row_count` | row count ≠ another model's | `compare_model` |
| `row_count_ratio` | rows / compare-model rows outside bounds | `compare_model`, `min_ratio`, `max_ratio` |
| `distinct_count_between` | distinct values outside bounds | `min_value`, `max_value` |
| `value_share` | share of rows equal to `value` outside bounds | `value`, `min_share`, `max_share` |
| `column_count_equal` | relation's column count ≠ expected (schema drift) | `value` |

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

Example — tolerate up to 1% orphaned keys instead of an all-or-nothing
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
| DuckDB | ✅ CI-verified | ✅ CI-verified | integration suite runs here |
| Postgres | ✅ expected | ✅ expected | |
| Snowflake | ✅ expected | ✅ expected | |
| BigQuery | ✅ expected | ✅ expected | `schema:` maps to a dataset |
| Redshift | ✅ expected | ✅ expected | |
| Databricks / Spark | ✅ expected | ✅ expected | |

"Expected" = built exclusively on dbt Core cross-database macros and dispatched
regex; not yet exercised in CI. Reports and adapter PRs are very welcome.

## FAQ

**Does it work with tests from other packages?**
Yes — the scoring hook reads dbt's run results, so every test in the invocation
is scored regardless of origin. dbt-expectations `expect_column_values_*` tests
are auto-detected as row-level.

**What happens on `dbt build`?**
Models run first, then tests; the hook fires once at the end and scores the
tests. Seeds and snapshots under test are included.

**Grouped tests (`unique`, `accepted_values`) report fewer failures than
affected rows — does that skew the score?**
Slightly, in the optimistic direction: dbt reports one failure per duplicated
value / rejected group, not per row. If that matters for a key test, set
`dqscore_mode: binary` on it.

**Can I score only some environments?**
Yes — `enabled: "{{ target.name == 'prod' }}"`.

**Does a failing quality gate hide my results?**
No. Results are stored before the gate raises, so the failing invocation is
visible in `dqscore_run_summary`.

**Can I keep a test out of the score?**
Yes — `config.meta.dqscore_exclude: true`. Useful for experimental checks or
inverted negative-path tests in CI.

## Integration tests

The suite covers:

1. **Happy path** — every bundled test against clean seeds (plus intentional
   `severity: warn` cases that exercise row-mode and binary-mode scoring).
2. **Negative path** — planted bad rows with `error_if: '=0'` so CI fails if a
   test *stops* catching bugs; those tests use `dqscore_exclude` so they don't
   pollute the KPI.
3. **Scoring assertions** — singular tests that verify `dqscore_*` tables,
   weights, and exact row/binary scores after the hook runs.

```
cd integration_tests
export DBT_PROFILES_DIR=.
dbt deps && dbt seed --full-refresh
dbt test --exclude tag:assert_scoring
dbt test --select tag:assert_scoring --vars '{dqscore: {enabled: false}}'
```

Requires `pip install dbt-duckdb` (or `uv pip install dbt-duckdb`). CI runs this
suite on every push.

## Publishing to dbt Hub

Getting listed on [hub.getdbt.com](https://hub.getdbt.com) is a registry step,
not a HubSpot form (that older intake path is gone). Requirements from
[hubcap](https://github.com/dbt-labs/hubcap) / dbt Labs best practices:

1. Public GitHub repo with a detectable open-source `LICENSE` (MIT ✅).
2. Root `dbt_project.yml` with `name:` and `require-dbt-version` (✅).
3. Semver GitHub **releases/tags** (`0.1.0` or `v0.1.0` — not `latest`).
4. Open a PR on [dbt-labs/hubcap](https://github.com/dbt-labs/hubcap) adding
   `dgvj-work/dbt_dqscore` to `hub.json`.
5. After merge, hubcap indexes new releases hourly.

See [What you should do next](#what-you-should-do-next) for a practical checklist.

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Releases follow
semantic versioning; breaking changes to test signatures or stored table schemas
only occur in minor versions before 1.0 and major versions after.

## Also available for pandas

Same philosophy — checks plus a single quality score — directly on DataFrames:
[dqscore on PyPI](https://pypi.org/project/dqscore/).

## License

[MIT](LICENSE)

---

## What you should do next

Concrete steps to ship `0.1.0` and land on the Hub:

1. **Push to GitHub** — this folder is not a git repo yet. `git init`, commit,
   create `https://github.com/dgvj-work/dbt_dqscore`, push `main`.
2. **Confirm CI is green** on GitHub Actions (DuckDB integration suite).
3. **Tag a release** — `git tag 0.1.0 && git push origin 0.1.0`, then create a
   GitHub Release with the CHANGELOG notes.
4. **Open the hubcap PR** — add your repo to
   [`hub.json`](https://github.com/dbt-labs/hubcap/blob/master/hub.json).
   Mention MIT license, DuckDB CI, and the scoring-hook use case in the PR body.
5. **Announce** in dbt Slack `#package-ecosystem` after it appears on the Hub.
6. **Later (raises Hub confidence):** add Postgres (and ideally Snowflake or
   BigQuery) to CI; bump examples to `arguments:` nesting for Fusion; collect
   one or two real adopter logos/issues.
