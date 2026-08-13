---
title: "`src/render.zig` review state"
id: docs/boris/src/render/review-state
parent: docs/boris/src/render
status: draft
tags: [boris, zig, source-reference, review, render]
---

# `src/render.zig` review state

## Status

Implemented and in production: the HTML path (and Aside inner bodies) render
Markdown through this seam. Oliver is pinned by content hash in `build.zig.zon`;
the pin, the compatibility wall (old renderer → Oliver deltas), and the upgrade
procedure live in `docs/contracts/oliver-renderer.md`.

## Known limitations / deferred

- Oliver-unsupported constructs (math, callouts, task lists, fenced divs, smart
  typography, captions) are not rendered; the only content that
  exercised them was the old renderer showcase guide, rewritten for Oliver.
  GFM strikethrough (`~~x~~`) **is** supported via Oliver's opt-in extension
  (pinned `18dc5ff`) because Boris's Textile contract emits it.
- If a future Boris feature needs one of these, implement the smallest
  principled feature in Oliver (with tests) and consume it through the seam —
  never a Boris-side parser hack.
