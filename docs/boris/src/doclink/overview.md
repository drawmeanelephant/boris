---
title: "`src/doclink.zig` overview"
id: docs/boris/src/doclink
status: draft
tags: [boris, zig, source-reference, doclink]
---

# `src/doclink.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/doclink/surface-and-execution|Surface and execution]]
* [[docs/boris/src/doclink/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/doclink/review-state|Review state]]

## Role in the pipeline

| Step | Owner | Relation to doclink |
| :-- | :-- | :-- |
| Parse / Textile adapt | `html_body` | Body ready |
| **Doc links** | **`doclink.rewrite`** | Source-relative `.md`/`.mdx` → `entity.html` (+ query/hash) |
| Includes | `include` | After doclink so owning-page source path still applies |
| Wiki-links | `wikilink` | Entity ids / fragments |
| Content-local images | `content_asset` | Sibling `.assets` |
| Aside → Apex | `aside` / `apex` | HTML |

Call site in `html_body.renderSource`: doclink first, then includes, with a deliberate first-slice limit that **included fragments do not re-resolve links against the including page**. Failures map to `error.ReferenceFailed`.[^4_1]

***
