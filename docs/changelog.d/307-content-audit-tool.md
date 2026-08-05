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
