---
title: "`src/layout_select_hostile_test.zig` surface and execution"
id: docs/boris/src/layout_select_hostile_test/surface-and-execution
parent: docs/boris/src/layout_select_hostile_test
status: draft
tags: [boris, zig, source-reference, surface, layout_select_hostile_test]
---

# `src/layout_select_hostile_test.zig` surface and execution

## Threat model

The file defends against the following categories of adversarial or erroneous input to the layout selection surface. Categories not exercised by this file are noted explicitly.

**Ambiguous glob rule sets (H2).** Two globs of equal specificity (same literal segment count) both matching an entity id. Threat: the engine silently picks one, producing non-deterministic layout assignment. Response required: `error.AmbiguousGlob` must be returned before any HTML is written, regardless of whether the two globs name the same layout path.

**Path traversal in layout paths (H5-traversal).** User supplies a layout path containing `..`, `/`-absolute prefix, `.` segment, backslash, or Windows drive letter. Threat: the engine resolves the path relative to a theme or working directory, silently reaching layouts outside the intended theme root. Response required: `error.InvalidLayoutPath` from `layout_select.validateLayoutPath`, surfaced as `error.InvalidValue` from `cli.parseOptions`, at both the library and CLI entry points. HTML must not be published.

**Missing layout file (H5-missing).** A valid-looking path is declared in a layout rule but the file does not exist on disk. Threat: the engine silently falls back to the next matching rule or the fallback layout, making the build appear to succeed while applying the wrong template. Response required: a build error (any I/O or layout-load error is acceptable — the exact class is not asserted); no HTML is published.

**Mixed theme roots (H5-mixed).** Rules reference layout files under different theme directories, or one rule uses a product-default path while the fallback uses a managed theme path. Threat: site output becomes inconsistently themed without a clear diagnostic. Response required: `error.MixedThemeRoots` from `target_mod.rejectMixedThemeRoots`; HTML must not be published.

**Invalid selector grammar (H5-selectors).** CLI receives `glob:ref*` (partial wildcard), `glob:**` (double-star wildcard), `role:branch` (invalid role name), `id:` (empty id), a duplicate selector for the same target, or `--layout-rule` combined with the incompatible `--out` flag. Threat: the engine accepts and misapplies malformed selectors, or silently ignores contradictory rule entries. Response required: `error.InvalidValue` or `error.DuplicateFlag` or `error.ConflictingFlags` from `cli.parseOptions`.

**Rule declaration order dependence (H3).** Rule slices presented in three distinct permutations. Threat: `selectLayout` applies rules in declaration order, causing identical rule sets in different orders to produce different selected layouts. Response required: identical `Selection` results and identical `ruleTableDigestMaterial` output for all permutations; HTML trees must be byte-identical.

**Stale HTML not cleaned after content removal (H8).** A content file is deleted between builds; a full rebuild follows. Threat: the engine leaves orphaned HTML in `dist/`. Response required: the orphaned HTML file is absent after the full rebuild.

**Incremental build not detecting layout-rule change (H7).** A layout rule is modified between two incremental builds. Threat: the engine's cache does not track the selected layout per page and serves the old HTML. Response required: `pages_written >= 1`; the output HTML carries the new layout marker.

**Multi-target cache namespace pollution (H6).** Two targets share a content root but have distinct rule sets. Threat: one target's cache entries influence the other's build, or both targets write to the same cache directory. Response required: each target's `.boris-cache/manifest.json` is distinct and stored under its own output root; HTML markers in each target's output reflect that target's rules only.

**Full vs incremental output divergence (H9).** Threat: the incremental code path emits different HTML than the full-build path. Response required: byte-identical output trees (excluding `.boris-cache/`).

**Repeated-run non-determinism (H10).** Threat: timestamps, random content, or non-deterministic iteration order causes successive full builds to differ. Response required: byte-identical output trees across three independent runs; manifest unchanged across no-op incremental runs.

**Categories not exercised by this file:**
- Renderer-seam error mapping in isolation — that is `src/render.zig`'s own tests.
- Concurrency or re-entrancy hazards in the compile pipeline.
- Filesystem permission failures or partial-write scenarios during HTML output.
- Cycle detection in the graph triggered by layout-rule inputs.
- Integer-width mismatches in rule table indexing beyond what Zig's type system catches at compile time.
