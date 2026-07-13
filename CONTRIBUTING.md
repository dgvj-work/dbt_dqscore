# Contributing to dbt_dqscore

Thanks for your interest! Bug reports, adapter fixes, new tests, and docs
improvements are all welcome.

## Development setup

```
pip install dbt-duckdb
cd integration_tests
export DBT_PROFILES_DIR=.
dbt deps && dbt seed --full-refresh
dbt test --exclude tag:assert_scoring
dbt test --select tag:assert_scoring --vars '{dqscore: {enabled: false}}'
```

The suite must finish green (warn-severity tests are intentional — they exercise
the scoring engine), log a `dqscore: quality score` line, and pass the
`tag:assert_scoring` singular tests.

## Adding a generic test

1. Add the `{% test ... %}` macro under `macros/generic_tests/` (thematic file).
2. Nulls should pass unless the test is explicitly about nulls.
3. Use dbt Core cross-database macros (`dbt.length`, `dbt.dateadd`, ...) — no
   adapter-specific SQL outside dispatch macros.
4. If the test returns one row per bad source row, add its name to the
   `row_level_defaults` list in `macros/scoring/store_test_results.sql`.
5. Add at least one usage to `integration_tests/models/schema.yml` and document
   it in the README table.

## Adding adapter support

Regex is the main dispatch point: add a
`<adapter>__dqscore_regexp_match` implementation in
`macros/utils/dqscore_regexp_match.sql`.

## Releases

Semantic versioning. Update `CHANGELOG.md`, tag the release (e.g. `0.2.0`), and
hub.getdbt.com picks it up automatically once the package is registered.
