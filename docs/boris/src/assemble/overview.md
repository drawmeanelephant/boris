---
title: "`src/assemble.zig` overview"
id: docs/boris/src/assemble
status: draft
tags: [boris, zig, source-reference, assemble]
---

# `src/assemble.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/assemble/surface-and-execution|Surface and execution]]
* [[docs/boris/src/assemble/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/assemble/review-state|Review state]]

## Executive summary

`src/assemble.zig` is the zero-copy layout planner and atomic page publisher for Boris HTML. It loads a layout template once, splits it into a closed plan of static slices, named slots, and optional `asset-url` helpers, then streams final pages with sequential writes — never a full-page mega-string. Publish uses Zig 0.16 `Dir.createFileAtomic` / `File.Atomic.replace`: write and flush a unique same-directory temp, then rename into the final path so a failed write leaves any prior final file intact.[^4_1]

The module exists so layout chrome (nav, breadcrumb, title, toc, children, metadata, footer, theme asset hrefs) stays a reusable immutable plan while per-page Whiteboard HTML lives only until flush completes. Trunk/Satellite graph identity stays in `graph.zig` / `compile.zig`; assemble only splices already-rendered fragments and publishes bytes under `dist`.[^4_2][^4_1]

Callers include `compile.zig` (`loadLayoutOnce`, `writePage` / `writePageWithSlotsOpts`, `precreateOutputDirs`, `scrubStaleAtomicTemps`), product HTML site builds, incremental/multi-target staging, harness/hardening paths, and `assemble_tests` under `zig build test`. Build wiring creates `assemble_mod` without linking Apex — assemble does not render Markdown.[^4_1]

Correctness properties it owns: required single `&#123;&#123;content&#125;&#125;`; no duplicate known markers; unknown tokens hard-fail at load; UTF-8 gate on layout raw; `asset-url` path grammar (`assets/…`, no `..`, ASCII-only); segment views into `Layout.raw` with lifetime tied to the long-lived layout arena; multi-slot stream order; atomic-ish same-dir replace; prior-final preservation on write failure; HoldUntilFlush flush-before-reset discipline for tests. What it does not own: body Markdown/Aside rendering, graph nav HTML generation, theme file copy, IR/RAG emit, or cross-volume atomic rename.[^4_1]

Confidence is high on the closed marker grammar, multi-slot/asset-url plan, sequential splice, and publish failure/replace unit matrix. Residual risk sits in platform rename windows (Windows `AccessDenied` during replace), cross-device not claimed, and caller misuse that resets the Whiteboard before `writePage` returns.[^4_1]

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Production layout splitter + multi-slot stream assembler + atomic file publisher + embedded unit tests |
| Conceptual domain | HTML layout plan; slot splice; `createFileAtomic` publish |
| Build or test root | Root of `assemble_mod` / `assemble_tests` (`zig build test`); imported by `compile.zig`, harness |
| Production runtime dependency | Yes — default HTML CLI path and all HTML targets |
| Expected execution command | `zig build test` (assemble unit tests + compile/HTML integration) |
| Main collaborators | `compile.zig`, `htmlnav.zig` / `htmltoc.zig` / `htmlbody.zig` (slot producers), `theme.zig`, `identity.zig` (relative hrefs), `docs/contracts/html-output.md`, `layouts/main.html` |
| Documentation depth warranted | High — HTML publish IO contract; layout authoring surface |


***

## Role in the Boris architecture

In the HTML pipeline, order is roughly: validate/load layout → discover/promote PageDb → graph freeze → per-page Whiteboard body render (includes, wiki, assets, Aside/Details, Apex) → fill `SlotValues` → **`assemble.writePageWithSlots*`** → stage commit / cache. Assemble is the last pure IO leaf of page materialization: it neither parses content nor talks to Apex.[^4_2][^4_1]

Layouts are process/build-lifetime. `Layout.raw` and all segment slices must outlive every `writePage` call for that target. Multi-target compile caches layouts by path; per-page selection only chooses which closed plan to stream. Incremental fingerprints include layout path/bytes (and nav material when slots need graph chrome) outside this module.[^4_2]

Against non-goals: no template language, no expression evaluation, no nested layouts, no MDX. Extension is a new marker or helper with split validation and tests — not a plugin registry.[^4_1]

***
