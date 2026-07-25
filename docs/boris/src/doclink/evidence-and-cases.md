---
title: "`src/doclink.zig` evidence and cases"
id: docs/boris/src/doclink/evidence-and-cases
parent: docs/boris/src/doclink
status: draft
tags: [boris, zig, source-reference, evidence, doclink]
---

# `src/doclink.zig` evidence and cases

## Tests (in-file)

Confirmed coverage from the packed source:[^4_1]

- Relative + root-style paths with query/hash suffixes
- Titles, angle destinations, escaping preserved around rewrite
- Ordinary contexts: heading, list, quote, table (four `../guide.html`-style hits)
- Left literal: external URL, scheme, mailto/tel-ish, non-`.md`, uppercase extension, missing page, escaped link, code span, raw HTML `<a href=…>`

Fixture nodes: `guide.md`, `nested/install.md`, `nested/index.md`, `guide.mdx`.[^4_1]

***
