---
title: "`src/include.zig` review state"
id: docs/boris/src/include/review-state
parent: docs/boris/src/include
status: draft
tags: [boris, zig, source-reference, review-state, include]
---

# `src/include.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Evidence gaps and uncertainties

- **`build.zig` not inspected** — the exact build step name and flags used to compile `include.zig` tests were not retrieved. It is assumed they run under `zig build test` based on standard Boris conventions, but this is uncertain.
- **`docs/contracts/includes-and-wiki-links.md` not retrieved** — the module declares itself normatively governed by this contract. Whether the implementation deviates from the contract in any edge case (e.g., fence interaction with indented code blocks, CRLF in directives) was not cross-checked.
- **`resolve_beneath` portability** — whether `resolve_beneath = true` is a no-op on any supported target is not determinable from this file alone.
- **Windows symlink test exclusion** — the symlink rejection test is entirely skipped on Windows. Symlink behavior on Windows is neither tested nor documented as a known gap here.
- **`errorCode` mapping lossy for DepthExceeded and ExpansionBudgetExceeded** — both map to `EINCLUDECYCLE`. Whether this is intentional (treating all cycle-adjacent conditions as one user-visible category) or an oversight is not documented in the file or comments.
- **`locus_path` empty at root** — `collectTransitiveIncludes` passes an empty `locus_path` for the root body and relies on the caller to supply the page's `source_path` when printing. This convention is documented in comments but not enforced by type — a caller could pass a non-empty locus for the root and the diagnostic path attribution would shift unexpectedly.

## Potential follow-up work

*This section is separated from the analysis above. It contains suggestions only, not claims about current behavior.*

- Factor the fence state machine into a shared type used by both `scanIncludeDirectives` and `expandRecursive` to eliminate the risk of the two implementations diverging.
- Add an explicit test for the `DepthExceeded` path independent of the cycle test, since the two are structurally different (stack size vs. reference cycle) even though they share a `diag.Code`.
- Document or fix the `EINCLUDECYCLE` reuse for `DepthExceeded` and `ExpansionBudgetExceeded` in the diagnostics contract.
- Add a test that verifies `copyCap` truncation behavior when detail or locus strings exceed 512 bytes, so consumers know the truncation is intentional.
- Consider adding a Windows-specific path for symlink testing or a documented note in the contract that symlink traversal security is POSIX-only.
- Retrieve and cross-check `docs/contracts/includes-and-wiki-links.md` against the implementation, especially fence handling and CRLF edge cases.
