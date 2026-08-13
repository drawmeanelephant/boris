---
title: "`src/html_toc.zig` review state"
id: docs/boris/src/html_toc/review-state
parent: docs/boris/src/html_toc
status: draft
tags: [boris, zig, source-reference, review-state, html_toc]
---

# `src/html_toc.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Behavioral gaps and residual uncertainty

- **Unclosed inner tags:** `stripTags` silently drops everything from an unclosed `<` to the end of inner content. This is structural behavior (not a contract violation for Oliver-produced HTML) but is not tested. The result is a truncated `text` value rather than an error.
- **Headings without a closing tag:** If `collectHeadingsInRange` finds an opening tag with an `id` but no matching `</hN>`, the heading is silently skipped (`i = gt + 1; continue`). No test asserts this.
- **Non-ASCII `id` bytes:** The parser treats all bytes opaquely. Multi-byte UTF-8 sequences in `id` values pass through to `extractIdAttr` and are returned as byte slices without validation. `appendEscaped` operates per byte and will correctly escape any `&`, `<`, `>`, `"` bytes regardless of multi-byte context. This is structurally correct but not explicitly tested.
- **Call sites:** The file that calls `renderToc` and `collectHeadingIds` in the production pipeline (likely `src/compile.zig`) was not inspected. Whether `&#123;&#123;toc&#125;&#125;` substitution and heading-fragment index building are wired correctly in the pipeline is not verifiable from this file alone.
- **Level constants as compile-time configuration:** `toc_min_level` and `toc_max_level` are exported `pub const` values. There is no mechanism to override them at runtime. A caller wanting a different TOC range must call `collectHeadingsInRange` directly.

***
