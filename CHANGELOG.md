# Changelog

## 0.1.1

- Add `required_if` generic test (conditional null checks)
- Add `proportion_in_range` generic test (tolerant range compliance rate)

## 0.1.0

Initial release.

- Scoring engine (`store_test_results` on-run-end hook):
  - row-weighted per-test scores (failing rows vs model row count)
  - per-test importance weights and mode overrides via `config: meta:`
  - `dqscore_exclude` meta flag to store a test without scoring it
  - per-model scores (`dqscore_model_scores`) and run rollup (`dqscore_run_summary`)
  - works with any tests: dbt built-ins, dbt-utils, dbt-expectations, custom
  - CI quality gate (`fail_below`), idempotent writes, `retention_days` cleanup
  - cross-adapter relation counts via `dbt.type_string()` (BigQuery-safe)
- 27 generic data quality tests (column, string, uniqueness, count/volume,
  statistical, temporal, relational), including `expression_is_true` and
  `column_pair_compare`
- Cross-database regex dispatch macro (quote-safe patterns)
- Quote-safe value lists for `in_set` / `not_in_set` / `value_share`
- DuckDB integration suite with scoring assertions and GitHub Actions CI
