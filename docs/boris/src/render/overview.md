---
title: "`src/render.zig` overview"
id: docs/boris/src/render
status: draft
tags: [boris, zig, source-reference, render, oliver]
---

# `src/render.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/render/surface-and-execution|Surface and execution]]
* [[docs/boris/src/render/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/render/review-state|Review state]]

## Executive summary

`src/render.zig` is Boris's single Markdown → HTML rendering seam. Production
rendering is delegated to the **Oliver** library (pinned by content hash in
`build.zig.zon`; see `docs/contracts/oliver-renderer.md`), consumed natively as
a Zig module — never a subprocess. This file is the only place Boris touches
Oliver's API, so an Oliver upgrade has exactly one seam to review.

The seam owns the renderer boundary: `oliver.parse` (with the dialect options
Boris publishes — footnotes, definition lists, heading attribute lists) then
`oliver.html.render` (heading auto-ids, footnotes section) into the caller's
Whiteboard arena. Input `md` is a slice into Whiteboard memory that Oliver
borrows; all produced bytes live on the arena, and the returned `Html.bytes`
view is valid until `arena.reset(.free_all)` — the identical lifetime contract
the previous renderer's `Html` had.

Because Oliver is a pure library with no global state, no hidden caches, and no
clock/network/filesystem access, parallel `--jobs` workers on independent
arenas are safe without the process-wide mutex the previous C engine required.
The module's tests pin the byte-exact heading-id output the compile pipeline
depends on, heading slug behavior (including duplicate headings sharing an id),
footnote/definition-list/table shapes, and dual-render determinism.
