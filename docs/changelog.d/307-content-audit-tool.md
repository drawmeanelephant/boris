<!--
Filename: <pr-number>-content-audit-tool.md (pr-number is the real PR number)
Keep exactly one category heading.
-->

### Added

- New standalone, deterministic, read-only [`boris-content-audit`](/tools/content-audit/)
  tool: audits poetry coverage, canonical parent alignment, verse density,
  placeholders, and mapping exceptions in an existing Boris content tree.
  Not part of publication, never writes to the source tree, and not wired into
  the root `zig build test` gate — build and test via
  [`tools/content-audit/build.zig`](/tools/content-audit/build.zig) or the root
  aggregate commands `zig build content-audit` and `zig build test-content-audit`.
  CI runs a dedicated content-audit lane on Linux and macOS with a strict
  success requirement in the aggregate `ci` job.
- Hardened [`boris-content-audit`](/tools/content-audit/): tool-owned output
  backup handling validates the ownership marker content, a bounded frontmatter
  grammar conforms to the Boris frontmatter contract, unregistered poetry shapes
  are never analyzed as paragraph units, Markdown fence semantics are honored,
  policy mapping tables are validated (stale keys, impossible targets, duplicate
  source/type coverage), delta compatibility is strict, collection filters scope
  every section consistently, and the consumer GitHub Actions workflow acquires
  a pinned tool build with exit-status capture.
