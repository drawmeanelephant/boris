---
title: "`src/html_nav.zig` overview"
id: docs/boris/src/html_nav
status: draft
tags: [boris, zig, source-reference, html_nav]
---

# `src/html_nav.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/html_nav/surface-and-execution|Surface and execution]]
* [[docs/boris/src/html_nav/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/html_nav/review-state|Review state]]

## Executive summary

`src/html_nav.zig` is the HTML navigation-chrome renderer for Boris Feature 6. It accepts a frozen, id-sorted `graph_mod.Node` slice and its companion `graph_mod.NavEntry` slice — both produced by `graph.zig` — and renders four distinct HTML fragments used to populate template placeholders in compiled output pages: `&#123;&#123;nav&#125;&#125;` (the full site forest), `&#123;&#123;breadcrumb&#125;&#125;` (the root-to-self ancestor chain), `&#123;&#123;children&#125;&#125;` (the direct Trunk children list), and `&#123;&#123;title&#125;&#125;` (the HTML-escaped page title text).

The file operates strictly at the HTML-string generation layer. It has no knowledge of the filesystem, frontmatter parsing, content pipeline scheduling, or the ApexMarkdown C engine. Its only inputs are caller-provided `std.mem.Allocator` instances and the already-validated, already-frozen graph data structures from `graph.zig`. All output is heap-allocated from the caller's allocator (in practice the document Whiteboard arena described in the module-level comment). The file owns no allocator of its own, performs no global state mutation, and holds no persistent resources.

`html_nav.zig` also provides `siteNavMaterial`, a helper that serializes ordered `(id, title, parent, role)` tuples into a null-byte–delimited buffer. This function is designed to feed a stable fingerprint for incremental-build cache invalidation: because it iterates the frozen, deterministically sorted node array, its output is byte-stable for a given content set regardless of hash-map iteration order.

The file contains four inline `test` declarations that run under the standard `zig build test` step, rooted through `src/main.zig` (the product `root_mod`). The tests exercise escape correctness, forest structure, child listing, breadcrumb construction, and a full pixel-exact output comparison for the deterministic landmark case. No test double, C ABI, or special build option is required; these are pure Zig unit tests.

The file depends on three siblings: `graph.zig` (for `Node`, `NavEntry`, `freeze`, `buildNav`, `freeNav`, `validate`), `identity.zig` (for `relativeHref`), and `diag.zig` (for `Diagnostic` and `countErrors`, used only in test setup). It is not directly registered as a separate test module in `build.zig`; its tests are reached transitively through the `root_mod` (main unit tests) and through the `assemble_mod` / `compile_mod` import chains that pull in the navigation chrome at production call sites.

The file's correctness model rests on three explicit contracts:
1. The `nodes` and `nav` slices passed to every render function must be the result of `graph.freeze` followed by `graph.buildNav`. Any caller that passes pre-freeze or partially-constructed data violates a documented precondition; the functions do not validate this themselves.
2. `current_index` must be a valid index into both slices. There is no bounds check inside the render functions beyond what Zig's safe-mode slice indexing provides in debug and ReleaseSafe builds.
3. `current_output_path` must be a valid site-root-relative path with `/` separators and no leading `/`, matching the same convention enforced by `identity.relativeHref`.

The file does not protect against: a `current_index` that exceeds `nodes.len` in unsafe release modes; a `nav[current_index].children` slice whose element values exceed `nodes.len`; or a `current_output_path` that contains path-traversal components (those would propagate into rendered `href` attributes without further validation, because `relativeHref` in `identity.zig` trusts its inputs).

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production library module with inline unit tests |
| Conceptual domain | HTML chrome generation; graph navigation rendering |
| Build or test root | Reached via `src/main.zig` (`root_mod`) and via `src/assemble.zig` / `src/compile.zig` import chains; tests run under `zig build test` |
| Production runtime dependency | Yes — called during HTML page compilation (Feature 6 / Milestone 9) |
| Expected execution command | `zig build test` (inline tests); `zig build` (production) |
| Main collaborators | `src/graph.zig` (Node, NavEntry, freeze, buildNav, freeNav, validate), `src/identity.zig` (relativeHref), `src/diag.zig` (Diagnostic — test setup only) |
| Documentation depth warranted | Medium — pure Zig, no C ABI boundary, behavior is structurally checked by tests |

***

## Role in the Boris architecture

`html_nav.zig` sits between the graph layer (`graph.zig`) and the template-splicing layer (`assemble.zig` / `compile.zig`). It is compiled into the product binary as a regular import; it is not test-only code. The `build.zig` `assemble_mod` and `compile_mod` declarations both pull in this file transitively when they import the HTML compilation surface.

This file has no relationship to the ApexMarkdown C engine (`src/apex.zig`, `vendor/apex/`). It does not import `apex.zig`, is not linked against `vendor/apex/apex.c` or `apex_hostile.c`, and does not appear in any `linkApex` call in `build.zig`. The hostile ABI test infrastructure (`apex_hostile_test.zig`, `apex_hostile.c`) is entirely unrelated to this file.

The file's inline tests (`zig build test`) run inside the `root_mod` test binary, which is also linked against the real ApexMarkdown via `linkApex(root_mod, b, false)`, but none of the tests in `html_nav.zig` call any Apex symbol. The Apex link is present because `root_mod` aggregates all product imports transitively; it is not an architectural coupling.

`html_nav.zig` is **not** involved in IR/JSON output (`manifest.json`, `graph.json`, `build-report.json`). It is the exclusively HTML-output-facing side of the pipeline, downstream of all validation, resolution, and serialization.

***
