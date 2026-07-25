---
title: "`src/harness.zig` surface and execution"
id: docs/boris/src/harness/surface-and-execution
parent: docs/boris/src/harness
status: draft
tags: [boris, zig, source-reference, surface, harness]
---

# `src/harness.zig` surface and execution

## Threat model

`src/harness.zig` is **not a hostile ABI test file**. It does not simulate malformed C outputs, dirty status codes, invalid pointer/length combinations, or allocator misuse. Its tests use the real Apex engine via the normal `apex.render` wrapper; no mock or double is involved.

The file does exercise several correctness properties that could degrade silently if broken:

**Graph structural invariants.** The invalid-graph test exercises five diagnostic codes against contract fixture content roots: `E_DUP_ID`, `E_PARENT_MISSING`, `E_PARENT_SELF`, `E_PARENT_CYCLE`, `E_PARENT_NOT_TRUNK`. Each is driven from a committed fixture under `docs/contracts/fixtures/`. This is a structural-correctness threat, not a C-ABI threat.

**Arena ownership and whiteboard reset isolation.** The whiteboard-reset test constructs a scenario where three pages are rendered sequentially with a shared `doc_arena` that is reset via `free_all` between pages, and titles are promoted from the arena into `PageDb` via explicit `dupe`. It asserts that PageDb-owned data survives the reset and that each output HTML file contains only its own content markers. This exercises the correctness of the arena ownership boundary between the per-page scratch allocator and the long-lived PageDb allocator.

**Output determinism.** The reproducibility test asserts byte-identical `graph.json`, `manifest.json`, and full dist trees across two independent pipeline runs against the same content. This is a property of the serialiser and sort order, not of C-ABI behaviour.

**Encoding gates.** Frontmatter and page-source UTF-8 BOM and invalid-UTF-8 inputs are expected to produce specific diagnostic codes before reaching any rendering stage.

**Layout marker validation.** `assemble.Layout.split` is exercised for missing and duplicate `&#123;&#123;content&#125;&#125;` markers, and the compile path is tested to abort before rendering pages when the layout is invalid.

No categories of C-ABI hostile behaviour (dirty outputs on error, null+nonzero length on success, allocator reentrancy, retained pointers, integer-width mismatches, calling-convention divergence) are present in this file. Those are covered by `src/apex_hostile_test.zig` and the inline `mapRenderResult` tests in `src/apex.zig`.

***
