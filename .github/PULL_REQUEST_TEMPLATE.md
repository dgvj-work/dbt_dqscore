## Summary

<!-- What does this PR change and why? -->

## Checklist

- [ ] `cd integration_tests && dbt seed && dbt test --exclude tag:assert_scoring && dbt test --select tag:assert_scoring` is green
- [ ] New generic tests are documented in the README table
- [ ] Row-returning tests are listed in `row_level_defaults` in `store_test_results.sql`
- [ ] CHANGELOG.md updated
