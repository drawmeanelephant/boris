---
title: "`src/include.zig` overview"
id: docs/boris/src/include
status: draft
tags: [boris, zig, source-reference, include]
---

# `src/include.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/include/surface-and-execution|Surface and execution]]
* [[docs/boris/src/include/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/include/review-state|Review state]]

## Executive summary

`src/include.zig` is the complete implementation of Boris's `&#123;&#123;include path&#125;&#125;` transclusion system — the mechanism by which one Markdown source file can embed the body of another before the document reaches Oliver or any downstream renderer. It is a pure Zig file-I/O and text-processing module; it operates entirely before the rendering stage. The module is self-contained: it defines the error set, failure-detail types, path grammar, scan logic, recursive graph traversal helpers, an expansion engine with a dual budget, a diagnostic mapping layer, and all unit tests in a single file.

The system boundary this file protects is the content filesystem. Every include path presented in source Markdown must name a real, non-symlinked, content-root-relative file that does not escape the content root through traversal components, backslashes, dot-segments, or symlink hops. Both the intermediate filesystem traversal in `readSourceAlloc` (which opens every directory component with `follow_symlinks = false`) and the final file open (which adds `resolve_beneath = true`) enforce this. An attacker or a careless author cannot reach files outside the declared content root by constructing an include directive.

The module is executed in two modes by callers. `collectTransitiveIncludes` performs a dry-run graph walk to discover which files a page touches — used during the build pipeline's dependency phase. `expandIncludes` (and its internal `expandIncludesWithBudget` variant) performs the actual text substitution, writing inline file content into an arena-owned result buffer while applying two resource guardrails simultaneously: a byte-budget ceiling (`max_expanded_bytes` = 16 MiB) and an expansion-count ceiling (`max_include_expansions` = 4096). Together these prevent exponential fan-out from files that each include the same target twice.

Cycle detection is maintained by an explicit path stack. In the scan/collect path the stack is checked linearly before each new visit and the `seen` set prevents re-reading files already visited; in the expansion path the stack alone guards cycles, while a `cache` map prevents re-expanding the same file's text twice (turning repeated-diamond includes from O(2^n) into O(n)). `FailInfo` records the first failure location and propagates it upward with string values copied into fixed-size inline buffers (`[^1_512]u8` each) so that nested file-buffer memory can be freed without use-after-free on the error string.

The file's self-tests cover: path grammar (relative-only, no dotfiles, no backslash, no traversal); directive scanning with backtick and tilde fence awareness; failure-detail capture; diagnostic code mapping and formatted output; simple and nested expansion with real `tmpDir` filesystem fixtures; cycle detection; missing-include attribution in nested contexts; exponential fan-out budget enforcement; and symlink rejection for both file and directory targets. The tests use `std.testing.tmpDir` and real filesystem I/O via `std.Io`, so they exercise the same `readSourceAlloc` path used in production. The module does not have separate unit and integration test suites; the embedded `test` blocks serve both purposes.

What the file does not prove: thread safety of concurrent calls to `expandIncludes` on shared caches (no shared state is used but no concurrency is tested); correct behavior under OS-level file permission errors beyond the `IncludeMissing` mapping; behavior when the `Io` abstraction is backed by an in-memory filesystem other than the tmpDir fixture; and the interaction between this module and the rendering stage (that boundary belongs to `src/render.zig` and its callers).

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production library module with embedded tests |
| Conceptual domain | Content-filesystem security; Markdown transclusion; resource budgeting; structured error reporting |
| Build or test root | Imported by production pipeline modules; tests run as part of `zig build test` |
| Production runtime dependency | Yes — `expandIncludes` / `collectTransitiveIncludes` are called on the content-compilation hot path |
| Expected execution command | `zig build test` (unit/integration tests embedded); production linkage via `@import("include.zig")` from pipeline callers |
| Main collaborators | `src/parser.zig` (frontmatter/body split via `bodyOfSource`); `src/diag.zig` (`Code`, `Diagnostic`, `formatText`); `std.Io` filesystem abstraction; `std.heap.ArenaAllocator` (arena-owned output) |
| Documentation depth warranted | High — security-relevant path validation, dual-budget resource guardrail, error-propagation invariants, and a subtle two-allocator ownership split all merit explicit documentation |

## Role in the Boris architecture

`src/include.zig` sits between the raw content filesystem and the Markdown rendering stage. After Boris discovers and parses a page's frontmatter with `src/parser.zig`, and before the page's Markdown body is handed to the Oliver-backed seam (`src/render.zig`) via `html_body.zig`, include directives are expanded in Zig. The module is not involved in rendering at all — its design comment ("Renderer file includes stay off; this module expands directives in Zig before Oliver runs") is accurate and supported by the absence of any `@import("render.zig")` in the file.

The module is linked into the production binary. It is not test-only. Because its tests use real filesystem I/O, they are integration-weight tests even though they live inside the source file; no test double or mock is used for the filesystem layer.

`collectTransitiveIncludes` feeds the build pipeline's static dependency graph: it tells callers which content files a given page transitively references without materialising the expanded text. `expandIncludes` then performs the actual substitution whose result feeds the Oliver rendering call. The `src/diag.zig` dependency is used only by `makeDiagnostic` and `printDiagnostic` — the diagnostic-formatting side — and not by the core expansion logic.
