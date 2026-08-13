---
title: "`src/render.zig` evidence and cases"
id: docs/boris/src/render/evidence-and-cases
parent: docs/boris/src/render
status: draft
tags: [boris, zig, source-reference, evidence, render]
---

# `src/render.zig` evidence and cases

## Evidence

| Claim | Evidence |
|-------|----------|
| Heading auto-ids match the observed contract (`hello-world`, `caf-rsum`, code-span text kept, duplicate headings share an id) | `zig build test-render` |
| Byte-exact body output (`<h1 id="alpha">Alpha</h1>\n` for `# Alpha\n`) | `test-render`; `src/compile.zig` multi-compile golden |
| Footnotes, definition lists, tables, fenced code render | `test-render` |
| Dual render is byte-identical (determinism) | `test-render` |
| Large input (64 KiB) stays bounded | `test-render` |
| Full suite green with the seam as the only renderer path | `zig build test` |

## Cases exercised

- Empty input → empty HTML
- Raw HTML passthrough (trusted author content) and escaped fenced code
- Unicode headings and entities in slugs
- Footnote refs + back-ref section; definition-list `<dl><dt><dd>` shape
- Renderer fuzz: bounded random bytes never crash (`src/fuzz.zig`
  `runRenderFuzz`)
