---
title: "`src/wikilink.zig` surface and execution"
id: docs/boris/src/wikilink/surface-and-execution
parent: docs/boris/src/wikilink
status: draft
tags: [boris, zig, source-reference, surface, wikilink]
---

# `src/wikilink.zig` surface and execution

## Threat model

This section describes the correctness and safety hazards that the design of `src/wikilink.zig` must handle. Because this module has no C ABI boundary, the threats are those of malformed input content and incorrect allocator usage, not hostile native-code injection.

**Malformed or adversarial wiki-link syntax in body content**

A body may contain `&#91;&#91;` tokens that are not valid wiki-links: empty entity IDs (`&#91;&#91;&#93;&#93;`), empty fragments (`&#91;&#91;entity#&#93;&#93;`), empty labels (`&#91;&#91;entity|&#93;&#93;`), unterminated brackets, newlines inside the link span, or entity IDs containing disallowed characters. The scanner must return `error.ReferenceSyntax` and fill `FailInfo` without reading out-of-bounds or appending a partial `WikiHit`. The evidence shows the scanner bounds-checks each step and validates the entity ID via `identity.validateEntityId` before committing the hit. Tests directly demonstrate several of these cases.

**Wiki-links inside fenced code blocks**

A wiki-link inside a backtick or tilde fence (run ≥ 3 at line start) must be ignored. The scanner maintains `fence_ch`/`fence_run` state and skips bytes when inside a fence. Tests confirm that `` ``` ``-fenced and `~~~`-fenced blocks suppress hit collection for both page-links and fragment-links.

**Reference to a nonexistent entity ID**

`&#91;&#91;missing/page&#93;&#93;` resolves against `nodes` (the frozen graph) via a hash map built from the caller-supplied node slice. If the entity ID is absent, `rewriteWikiLinks` returns `error.ReferenceMissing` and fills `FailInfo` with the entity ID and position. This is structurally checked: the `findNodeMap` call is gated on a non-null return.

**Fragment on a nonexistent entity**

`&#91;&#91;typo#section-one&#93;&#93;` where `typo` is not a known entity should report a missing page, not a missing heading on a nonexistent page. The `HeadingIndex.Lookup` enum distinguishes `.unknown_entity` from `.unknown_fragment`, and `checkFragment` routes `.unknown_entity` through the entity-missing diagnostic path (detail without `#`). A test (`"plan path reports missing entity, not missing heading, for &#91;&#91;typo#frag&#93;&#93;"`) directly demonstrates this.

**Fragment on an existing entity without a matching heading**

`&#91;&#91;guides/overview#nope&#93;&#93;` where `guides/overview` is indexed but `nope` is not one of its heading IDs returns `.unknown_fragment`, and `failFragmentDetail` fills detail with `entity_id#frag` so `messageFor` produces the heading-specific message. A test directly demonstrates this.

**Fragment validation requested but no `HeadingIndex` supplied**

When `ResolveOptions.validate_fragments = true` and `heading_index = null`, the absence of an index means any fragment fails immediately (`error.ReferenceMissing`). This fail-closed behavior is structurally enforced: `checkFragment` checks `opts.heading_index orelse { …; return error.ReferenceMissing; }`. A test confirms this.

**Bootstrap mode: fragment emitted without validation**

When `validate_fragments = false`, `checkFragment` returns immediately without consulting the index. This is the deliberate bootstrap mode for the first render pass that populates heading IDs. A test confirms that a fragment link is emitted correctly when this option is set.

**Output slice construction from body views**

`scanWikiLinks` appends `WikiHit` structs with slices (`entity_id`, `fragment`, `label`) that are views into the caller-supplied `body` slice, not owned copies. These slices are valid only for the lifetime of `body`. `rewriteWikiLinksOpts` uses them only within the same function scope before the output is written; they are not stored past the function's frame. No test directly verifies the lifetime enforcement — this is a structural property of the call graph, not a proven ABI contract.

**Allocation failure**

All allocation sites use `try` or `errdefer`; `WikiError` includes `error.OutOfMemory` and `makeDiagnostic` maps it to `diag.Code.EIO`. The `HeadingIndex.putOwned` function includes an `errdefer` sequence that frees partially-allocated items before propagating the error. These are structurally checked by code, not demonstrated by OOM injection tests.

**`FailInfo` detail truncation**

`FailInfo` uses a fixed-capacity inline buffer of `max_fail_str` bytes (512, from `include.zig`). Detail strings longer than 512 bytes are silently truncated. No test exercises this boundary. This is a contract-only bound.

**`referenceMaterialMulti` with mismatched `body_paths` length**

If `body_paths` is non-null and its length differs from `bodies.len`, the function returns `error.PathError` immediately. This is structurally checked.

**`materialFromIdLocs` determinism**

The fingerprint material emits entity-ID-sorted NUL-delimited records. The sort is performed on a copied slice (not in-place on the caller's data), and a stable sort comparator is used. The sorting behavior is not directly tested by an assertion on output byte order in the embedded tests; determinism is structurally implied by the `std.mem.sort` call with a lexicographic comparator.

**Untested categories**

- Out-of-memory injection during `HeadingIndex.putOwned` or `rewriteWikiLinksOpts` output buffer growth: not tested
- `encodeFragment` with multi-byte UTF-8 input (percent-encodes each byte independently; behavior on valid UTF-8 is structurally correct but not tested for multi-byte sequences)
- `printDiagnostic` output format (calls `makeDiagnostic` then `diag.formatText`; failure paths swallow errors silently)
- `referenceMaterialMulti` called with `body_paths` non-null: one test (`"referenceMaterialMulti missing target keeps include locus"`) covers this path
