---
title: "`src/frontmatter.zig` overview"
id: docs/boris/src/frontmatter
status: draft
tags: [boris, zig, source-reference, frontmatter]
---

# `src/frontmatter.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/frontmatter/surface-and-execution|Surface and execution]]
* [[docs/boris/src/frontmatter/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/frontmatter/review-state|Review state]]

## Executive summary

`src/frontmatter.zig` is the bounded frontmatter parser for Boris v0.1. It ingests the raw bytes of a content file and extracts a small, explicitly enumerated set of metadata fields — `id`, `title`, `parent`, `status`, and `tags` — from a `---`-fenced header, returning a `Meta` struct whose string fields are allocated into a caller-supplied retain arena. The file is unambiguously *not* a YAML parser: it implements a deliberately narrow, line-oriented `key: value` grammar and actively rejects YAML forms it does not support, including block scalars, flow collections, anchors, aliases, and single-quoted strings.

The file exists because Boris must parse metadata from Markdown content files before any rendering takes place, and that metadata must be validated, size-bounded, and durably owned without risking oversized allocations entering the compile-session arena. `frontmatter.zig` enforces all three of those properties in one place, making it the primary content-input validation boundary for the identity and graph subsystems.

It is executed as part of the `src/parser.zig`-rooted test module (the `--frontmatter-parser` build step), and its `parse` function is called from the production pipeline via the parser layer. It is also the unit-test home for the `Status`, `Meta`, and `validateId` declarations. Its co-located tests cover the happy path, duplicate-key rejection, unknown-key resilience, oversize-value rejection with arena-size verification, trailing-comma tag rejection, and exact-limit boundary acceptance.

The file provides strong confidence that:
- valid well-formed frontmatter produces the correct `Meta` values with zero diagnostics;
- every known malformed input produces exactly one or more `EFRONTMATTER` or `EINVALIDUTF8` diagnostics without returning an error (only OOM can do that);
- oversized `title` and `id` values are rejected *before* being copied into the retain arena, protecting the long-lived compile-run arena from inflation by adversarial content;
- length constants are centralized in `page.zig` and `identity.zig` so there is a single source of truth for bounds.

What the file does *not* prove:
- that all call sites correctly pass separate `retain` and `list_gpa` allocators (structural, not tested here);
- that the `source_path` pointer outlives the `diags` list (documented contract, not enforced mechanically);
- behavior under concurrent access (the parser is purely synchronous and non-reentrant by structure, but no test demonstrates this);
- exhaustive fuzz coverage (a separate `src/fuzz.zig` target is declared in `build.zig` for that purpose);
- correct behavior when `max_tag_bytes` or `max_tag_count` limits from `page.zig` are violated (those limits exist in `page.zig` but are **not** enforced by `frontmatter.zig` — see gaps below).

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production library + co-located unit tests |
| Conceptual domain | Content metadata parsing, input validation, diagnostic emission |
| Build or test root | `src/parser.zig` (imported as a dependency); tests compiled via the `parser_mod` step in `build.zig` |
| Production runtime dependency | Yes — called by the production pipeline through `parser.zig` |
| Expected execution command | `zig build test` (runs as part of default test suite via `run_parser_tests`) |
| Main collaborators | `src/diag.zig` (Diagnostic / Code types), `src/page.zig` (limit constants, Status re-export), `src/identity.zig` via `src/pathutil.zig` (validateEntityId) |
| Documentation depth warranted | Medium-high: it is the primary content-input gate; its allocation contracts and rejection guarantees are load-bearing |

***

## Role in the Boris architecture

`src/frontmatter.zig` sits at the **input validation layer** of the pipeline, between raw file bytes and the durable `PageDb`. Its `parse` function is called by `src/parser.zig`, which is in turn called by the pipeline (milestone 5–6 path) after a file is discovered by the scanner. The result `Meta` struct carries string slices that are allocated into the caller's retain arena; those slices are later promoted into `DurablePage` entries in `PageDb.promote()`.

It has no dependency on the Apex C ABI, on `src/apex.zig`, on any hostile test double, or on any rendering subsystem. It is compiled into the product binary as a plain Zig module with no special link flags. Unlike the `apex_hostile_test.zig` target, it appears in the default `zig build test` suite and in the production executable.

The `Status` enum declared here is a local copy of the `Status` from `page.zig` — both are identical closed three-member enums. This duplication is the most notable structural redundancy in the file; see the gaps section.

The limit constants `max_title_bytes` and `max_entity_id_bytes` are re-exported from `page.zig`, which in turn re-exports `max_entity_id_bytes` from `identity.zig`. This two-hop re-export chain means `frontmatter.zig` is correctly downstream of the single source of truth.

***
