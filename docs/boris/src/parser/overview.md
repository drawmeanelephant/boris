---
title: "`src/parser.zig` overview"
id: docs/boris/src/parser
status: draft
tags: [boris, zig, source-reference, parser, frontmatter]
---

# `src/parser.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/parser/surface-and-execution|Surface and execution]]
* [[docs/boris/src/parser/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/parser/review-state|Review state]]

## Executive summary

`src/parser.zig` is the frontmatter-and-body splitter at the heart of the Boris content compiler. It defines a deliberately closed, non-YAML, line-oriented grammar for the small subset of structured metadata that Boris accepts at the top of each Markdown source file. Its single public entry point, `parse(source: []const u8) ParseResult`, accepts a complete file's bytes and returns either a `ParsedDocument` (containing views into the caller-supplied buffer plus a parsed `FrontmatterView`) or a `ParseResult` carrying a `Diagnostic` with a stable machine-readable category, a 1-based line and column, and a static human message. The function performs no allocation whatsoever; all string fields in the output are slices that point directly into the caller's `source` buffer.

The file exists because Boris must ingest content written by human authors who may introduce syntactic noise — stray YAML constructs, wrong line endings, BOM markers, overlong fields, path-traversal ids, duplicate keys, unclosed fences — at the frontmatter layer before any graph or identity logic runs. By providing a single, tested, allocation-free parse function with a closed key set and explicit size limits, Boris prevents ambiguous or unbounded input from propagating into downstream pipeline stages (discovery, `PageDb` promotion, graph resolution, IR emission). The parser is the first correctness gate in the Boris pipeline.

The file is compiled as part of the production `boris` binary: there is no separate test-only build path. The embedded `test` blocks are run through `zig build test` (or `zig test src/parser.zig` with appropriate import resolution). They exercise both inline inputs and fixture files under `fixtures/content/`. The fixture-driven tests require the working directory to be the package root; the helper `readFixture` emits a `std.log.err` and returns the underlying error on open failure rather than panicking.

The parser provides high confidence on the positive path (a complete valid frontmatter round-trip is demonstrated inline and via `fixtures/content/valid/`) and on the negative paths for every error category it defines. It does not test behavior after the body boundary, does not render or validate Markdown syntax in the body, and does not resolve parent references against any graph — those responsibilities belong to `scanner.zig`, `page.zig`, and the graph stage. The lifetime contract (caller must dupe source-view slices before freeing the source buffer) is documented in module comments and exercised in `page.zig`'s `PageDb.promote` test, not within `parser.zig` itself.

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production library with embedded unit tests |
| Conceptual domain | Content parsing — frontmatter grammar, body extraction, diagnostic emission |
| Build or test root | Compiled into the `boris` production binary; tests run via `zig build test` from package root |
| Production runtime dependency | Yes — `scanner.zig` and the pipeline call `parser.parse` on every content file |
| Expected execution command | `zig build test` (all tests) or `zig test src/parser.zig` with dependency modules on the path |
| Main collaborators | `src/page.zig` (bounds constants, `FrontmatterView`, `Status`, `RelationKind`, `SemanticRelation`), `src/identity.zig` (`validateEntityId`), `fixtures/content/` (fixture corpus) |
| Documentation depth warranted | High — this is the primary input boundary for all Boris content; every error category directly affects author-facing diagnostics |

***

## Role in the Boris architecture

`src/parser.zig` occupies the second stage of the Boris pipeline, immediately after file discovery. It is not an integration point with the Markdown renderer; it operates entirely on raw source bytes before the body is ever handed to a renderer. It has no dependency on `src/render.zig`.

The typical call chain is:

```text
scanner / pipeline
    → reads source file bytes into a temporary buffer
    → parser.parse(source)            ← this file
    → ParseResult { doc, diagnostic }
    → if ok: PageDb.promote(discovery, entity_id, doc.meta, doc.body_offset)
        → dupe source-view strings onto retain arena
        → free temporary source buffer
    → if error: emit diagnostic, skip or halt
```

The parser is a pure function library; it holds no state between calls. It is linked directly into the production binary and called once per discovered content file per build run. Its outputs feed `page.zig`'s `PageDb.promote`, which is responsible for copying all source-view strings onto a long-lived retain arena before the source buffer is freed. The parser itself never touches an allocator.

Relation to the test suite: `parser.zig` carries its own `test` blocks rather than being exercised exclusively from a separate file. The fixture-driven tests form a small corpus-level contract: valid fixture files must parse without error; invalid fixture files whose invalidity is a frontmatter concern must produce the correct category; graph-invalid fixture files (missing parents, cycles, duplicate IDs) must parse successfully, because graph problems are not parser errors.

***
