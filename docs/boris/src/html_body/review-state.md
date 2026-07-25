---
title: "`src/html_body.zig` review state"
id: docs/boris/src/html_body/review-state
parent: docs/boris/src/html_body
status: draft
tags: [boris, zig, source-reference, review-state, html_body]
---

# `src/html_body.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Gaps and uncertainties

- **Textile path is not tested inline.** `bodyForInput` contains a `textile.toMarkdown` branch, but no test in this file exercises it. Coverage presumably exists in `textile.zig`'s own tests and possibly in `compile.zig` tests.
- **Error paths in `renderSource` are not tested here.** All six failure modes listed above are reachable but not exercised by the two inline tests.
- **Apex render failure within a segment loop.** If `apex.render` fails partway through iterating `tok.segments`, the partially constructed `html_buf` is abandoned and the error is returned. Whether callers handle partial output correctly is a question for `compile.zig`'s tests.
- **`html_buf` growth under large documents.** The `html_buf.appendSlice(arena, ...)` call reallocates within the arena as the HTML grows. The arena may allocate multiple backing blocks. This is structurally safe but means `html_buf.items.ptr` may not equal the address of any single allocation visible to external tools. This is noted only as an architectural observation, not a defect.
- **`writeTestFile` uses `std.testing.allocator` and `Io.Dir.cwd()` directly.** The test helper is not guarded against concurrent test execution in environments that run tests in parallel. Whether Boris's test runner can trigger this is uncertain.
- **`quiet` propagation for asset diagnostics.** The `content_asset.printDiagnostic` path correctly checks `!options.quiet` before printing, consistent with the other stages. This is structurally verified by code inspection, not by a test in this file.

***

## Potential follow-up work

> This section records observations that may warrant future attention. It does not represent committed work or confirmed defects.

- Add tests for `error.TextileFailed`, `error.IncludeFailed`, `error.ReferenceFailed`, `error.ComponentFailed`, and `error.RenderFailed` paths through `renderSource` directly in this file, rather than relying on coverage from `compile.zig`.
- Consider testing `renderSource` with `quiet: false` to verify that diagnostics are printed rather than silently swallowed; current tests use the default (`quiet: true`).
- The `writeTestFile` helper could be extracted into a shared test utilities module if a similar pattern appears elsewhere.
- Document the `html_buf` arena-backed `ArrayList` pattern (no `deinit`, arena owns storage) more explicitly at the declaration site to avoid future attempts to add a `defer html_buf.deinit(arena)` cleanup.
