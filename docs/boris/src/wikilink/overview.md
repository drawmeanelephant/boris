---
title: "`src/wikilink.zig` overview"
id: docs/boris/src/wikilink
status: draft
tags: [boris, zig, source-reference, wikilink]
---

# `src/wikilink.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/wikilink/surface-and-execution|Surface and execution]]
* [[docs/boris/src/wikilink/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/wikilink/review-state|Review state]]

## Executive summary

`src/wikilink.zig` implements Boris's wiki-link subsystem: the scanning, validation, rewriting, and diagnostic machinery for Obsidian-style `&#91;&#91;entity-id&#93;&#93;` cross-references embedded in Markdown source bodies. It operates entirely within Zig, on raw UTF-8 byte slices, and runs before any Apex Markdown rendering pass. Its three primary concerns are (1) correctly identifying wiki-link tokens outside fenced-code blocks, (2) resolving those tokens against the frozen page graph and optionally against a per-page `HeadingIndex` of Apex-rendered heading IDs, and (3) rewriting them into standard Markdown `[label](href)` links or emitting structured diagnostics when resolution fails.

The file is self-contained in terms of parsing: it implements its own fence-aware scanner, its own entity-ID character classifier, and its own RFC 3986 percent-encoder for fragment identifiers. It borrows `FailInfo` and `lineColAt` from `src/include.zig` (the include-expansion subsystem), establishing a shared diagnostic-record pattern across both pre-render content transformations. It imports `graph.zig` for the `Node` type and `identity.zig` for `validateEntityId`, `htmlOutputPath`, and `relativeHref`. The `diag.zig` module supplies `Code` constants, `Diagnostic`, and `formatText`.

The file exists because wiki-links are a first-class Boris navigation primitive: they must be resolved against the deterministic content graph before Apex converts Markdown to HTML. Resolving them pre-Apex preserves the ability to (a) detect broken links at compile time with precise line/column diagnostics and (b) emit standard Markdown `[…](…)` syntax that Apex can then process as ordinary links. Fragment validation (`&#91;&#91;entity#heading-id&#93;&#93;`) adds a second-order correctness requirement: a fragment is only valid if the rendered heading ID actually appears on the target page, which requires a previously-populated `HeadingIndex`; the `ResolveOptions.validate_fragments` flag and the bootstrap mode (`validate_fragments = false`) encode the two-phase bootstrapping contract explicitly in the API.

The file is compiled into the production Boris binary and is not test-only. All tests are embedded at the bottom of the file and run via `zig build test` or `zig test src/wikilink.zig` with appropriate module resolution. No hostile or double C implementations are involved; this module has no C ABI boundary. Its correctness envelope covers pure-Zig logic: scanner state machine correctness, ownership of output slices, allocation with `errdefer` cleanup, and diagnostic fidelity.

What the file does not prove or cover: it does not validate that `HeadingIndex` was populated from the same Apex rendering pass that will render the consuming page (a lifecycle ordering contract not enforceable within this module); it does not test behavior under concurrent access (there is no shared mutable state between calls, but no formal proof of concurrent safety is present); and it does not exercise the integration path through `src/pipeline.zig` or `src/rag.zig` where `referenceMaterialMulti` is called in a multi-body context.

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production module with embedded unit tests |
| Conceptual domain | Content pre-processing; wiki-link scan, resolve, rewrite, diagnostics |
| Build or test root | Compiled into the Boris binary; tests run via `zig build test` |
| Production runtime dependency | Yes — required before any Apex render of body content |
| Expected execution command | `zig build test` (all modules); or `zig test src/wikilink.zig` with `-I src` module flags |
| Main collaborators | `src/include.zig` (FailInfo, lineColAt), `src/graph.zig` (Node), `src/identity.zig` (validateEntityId, htmlOutputPath, relativeHref), `src/diag.zig` (Code, Diagnostic, formatText) |
| Documentation depth warranted | High — central content transformation with multi-phase bootstrapping contract, fragment validation invariant, and diagnostic ownership model |

## Role in the Boris architecture

`src/wikilink.zig` sits in the pre-render content transformation layer, operating on raw Markdown body bytes after frontmatter is stripped but before any Apex call. In the intended pipeline (`source content → identity discovery → metadata/relationship resolution → validation → structured IR/manifest output → frontend rendering`), this module participates in the IR/manifest output phase: it contributes to `referenceMaterial` fingerprints that determine whether a page's cached compilation is stale, and it performs the actual link-text rewriting that produces the Apex-ready Markdown body.

It is not the hostile ABI test or a wrapper around a C library. It has no linkage to `src/apex.zig` and is not linked against ApexMarkdown or any external native library. It is linked into the production binary as an ordinary Zig import. The file's tests are co-located with the implementation and exercise only Zig functions through Zig call sites; there is no mock or double for any collaborator.

Relative to the rest of the Boris architecture, `src/include.zig` is the closest structural peer: both perform fence-aware pre-render scanning, both use `FailInfo` for inline-buffer diagnostic records, and both expose a `makeDiagnostic`/`printDiagnostic` pair. The wikilink module depends on the include module only for the shared `FailInfo` type and `lineColAt` helper, not for the include-expansion logic itself.
