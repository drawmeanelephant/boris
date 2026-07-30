# Astro import-plan Draft 2020-12 validation

This is a test-only contract lane. Ajv is not a Boris runtime dependency and is
not used to parse sources or execute plans.

From `tools/migration-lab/`:

```sh
npm --prefix schema-validation ci --ignore-scripts
zig build schema-test
```

The matrix compiles all three schemas with Ajv's Draft 2020-12 implementation,
validates committed payloads that the Zig tests compare with current runtime
emission, independently recomputes policy/source-tree/snapshot/plan digests,
and requires every named malformed mutant in `validate.mjs` to fail for its
expected schema keyword. It never silently skips when Ajv is absent.

Cross-record uniqueness, normalized collision grouping, same-path manifest
ownership, and digest equality remain runtime checks because JSON Schema cannot
express them completely.
