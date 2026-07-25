---
title: "`src/identity.zig` review state"
id: docs/boris/src/identity/review-state
parent: docs/boris/src/identity
status: draft
tags: [boris, zig, source-reference, review-state, identity]
---

# `src/identity.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Gaps and untested properties

The following properties are **not** mechanically tested or enforced by this file's test suite:

- **Call-site enforcement:** Nothing in the type system prevents a caller from constructing an entity id by methods other than `canonicalEntityId`. The re-validation in output-path functions mitigates but does not eliminate risk.
- **Non-ASCII Unicode:** The module treats all bytes as opaque except for the ASCII characters it explicitly checks (`/`, `\`, `.`, ` `, `\t`, `\n`, `\r`, `:`, `A-Z` in drive detection). Unicode normalization (NFC/NFD), homoglyph attacks, and non-BMP codepoints are out of scope and untested.
- **Path depth > 32 in `relativeHref`:** `splitPathComponents` silently truncates at 32 components. No test, no error return.
- **`normalizeEntityId` call sites:** This function allocates and normalizes a stem or frontmatter id, but no test in this file exercises it directly. It exists to support future frontmatter `id:` override processing; whether all callers use it correctly is uncertain.
- **`htmlOutputPath` alias:** Tested only indirectly through `safeOutputRelativePath`; if the alias contract diverged it would not be independently detected.
- **ASan/UBSan coverage:** The sanitizer build target in `build.zig` covers the Apex C adapter, not `identity.zig`. Allocator misuse in pure-Zig code relies on `std.testing.allocator`'s leak detection in test mode.
- **Filesystem case-sensitivity at the scanner level:** `pathsDifferOnlyInCase` is exported and tested implicitly through `validateEntityId` shape tests, but no test exercises a two-file collision scenario end-to-end through the scanner.

## Potential follow-up work

> **Documentation only — no code changes are proposed here.**

- Add a dedicated `zig build test-identity` build target so identity tests can be run in isolation without the full scanner module.
- Add a test for `relativeHref` with directory depth > 32 to make the truncation behavior explicit (document as a known limitation or add a compile-time bounded error return).
- Add at least one test for `normalizeEntityId` to confirm it handles the frontmatter `id:` override path (backslash normalization of a raw frontmatter value).
- Consider whether `splitPathComponents`'s capacity limit (32) should emit a runtime error rather than silently truncating; document the current behavior explicitly in the function comment.
- The ASan/UBSan smoke step (`test-apex-sanitize`) covers the C adapter only; a separate sanitizer pass over the Zig-only identity logic (e.g., via `zig build test -Doptimize=Debug` with `std.testing.allocator`) could confirm leak-freedom under all error branches.
