---
title: "`src/html_toc.zig` overview"
id: docs/boris/src/html_toc
status: draft
tags: [boris, zig, source-reference, html_toc]
---

# `src/html_toc.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/html_toc/surface-and-execution|Surface and execution]]
* [[docs/boris/src/html_toc/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/html_toc/review-state|Review state]]

## Executive summary

`src/html_toc.zig` is the in-page table-of-contents subsystem for Boris. It implements Feature 6 follow-on (Feature 6b in the status map): given the already-rendered body HTML produced by Oliver (and any Aside component HTML), it harvests heading elements with `id` attributes and synthesizes an accessible `<nav>` fragment for the `&#123;&#123;toc&#125;&#125;` template placeholder.

The file has a precise, narrow contract: it does not re-implement Oliver's heading-slug rules, it does not parse Markdown, and it does not own the rendering pipeline. Its input is finished HTML; its output is either a caller-owned HTML string or a deduplicated list of heading `id` slices. The heading IDs it extracts are the same anchors that Oliver emits, so `href="#id"` links in the TOC are structurally consistent with the rest of the rendered page without any coordination overhead.

The module exposes three public entry points (`collectHeadingsInRange`, `collectHeadings`, `collectHeadingIds`, and `renderToc`) and a single public struct (`Heading`) plus two exported level-range constants (`toc_min_level`/`toc_max_level` for the TOC view and `fragment_min_level`/`fragment_max_level` for the full wiki-fragment target set). All heap allocations go through caller-supplied `std.mem.Allocator` arguments; there is no module-level state. Ownership rules are documented inline: `id` slices point into the input `html` buffer; `text` slices are allocator-owned and must be freed per item.

The file includes eight embedded Zig tests. These tests exercise: level filtering, entity preservation, tag stripping from inner HTML, the `>` character inside quoted attribute values (a well-known parser edge case), false-positive `id` extraction from attributes like `data-id`, TOC HTML shape and ARIA attributes, allocation-failure cleanup under `std.testing.checkAllAllocationFailures`, and the deduplicated `collectHeadingIds` path. The tests are compiled as part of the standard `zig build test` suite via the `root_mod` unit test artifact; no separate build step is required.

The file does not interact with the Markdown rendering seam and does not import `src/render.zig`. Its only non-standard import is `src/html_nav.zig`, from which it calls `html_nav.appendEscaped` to HTML-escape the extracted `id` value when constructing `href` attribute values. This is the single cross-module dependency.

What the file does not prove: it does not prove correct handling of malformed or deeply nested HTML beyond its documented scan strategy; it does not handle multi-byte UTF-8 sequences differently from byte sequences (treating them as opaque bytes, which is correct for ASCII-structured HTML tag parsing but means non-ASCII `id` values are passed through without validation); it does not guarantee that heading IDs in the emitted TOC actually resolve to anchors in the same document (that consistency property depends on the surrounding pipeline producing coherent output, not on this module alone).

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production library module with embedded unit tests |
| Conceptual domain | HTML post-processing; in-page navigation chrome generation |
| Build or test root | Compiled as part of `src/main.zig` root module; tested via `run_unit_tests` in `zig build test` |
| Production runtime dependency | Yes — called on every compiled page that uses the `&#123;&#123;toc&#125;&#125;` placeholder |
| Expected execution command | `zig build test` (embedded tests run with unit tests); no separate step |
| Main collaborators | `src/html_nav.zig` (`appendEscaped`); callers in `src/compile.zig` or equivalent pipeline stage (uncertain — not inspected) |
| Documentation depth warranted | Medium; the module is self-contained, well-tested, and its public API surface is small |

***

## Role in the Boris architecture

`src/html_toc.zig` is a pure post-processing pass that operates entirely within the **Ignite** stage of the Boris pipeline (Load → Roll → Ignite → Reset). By the time it is invoked, Oliver has already converted Markdown source to body HTML, and Aside components have been rendered. The module reads that HTML without modifying it.

It is linked into the **product binary** through the main module (`src/main.zig`). It is not isolated to a test-only build; every `boris` invocation that compiles pages with `&#123;&#123;toc&#125;&#125;` calls into this module at runtime.

The module has no relationship to `src/render.zig` or to the Oliver-backed rendering seam. It consumes rendered HTML (a Zig `[]const u8` string) rather than the renderer's API.

The `html_nav.zig` dependency is narrow: `renderToc` calls `html_nav.appendEscaped` to escape the heading `id` string before placing it in an `href="..."` attribute. This prevents raw `&`, `<`, `>`, and `"` characters in heading IDs from producing malformed HTML or attribute injection.

The file's embedded tests run as part of the main unit test artifact (`root_mod`). No separate module or build artifact is defined for it. Because the tests are embedded (using Zig's `test` blocks), they are discovered automatically when the test runner walks the import graph from `src/main.zig`.

***
