---
title: "`src/frontmatter.zig` review state"
id: docs/boris/src/frontmatter/review-state
parent: docs/boris/src/frontmatter
status: draft
tags: [boris, zig, source-reference, review-state, frontmatter]
---

# `src/frontmatter.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

The following observations are in this section only and do not reflect current defects:

1. **Enforce `max_tag_count` and `max_tag_bytes`**: The parser currently accepts arbitrarily many tags and arbitrarily long tag tokens. Adding checks consistent with the limits in `page.zig` would close the gap between the documented contract and the enforced behavior.
2. **Enforce `max_frontmatter_bytes`**: A very large frontmatter block (> 64 KiB) is processed without a byte cap. Adding an early check after the opening fence would protect against pathological inputs.
3. **Unify `frontmatter.Status` with `page.Status`**: The duplicate declaration creates a type mismatch between `frontmatter.Meta.status` and `page.FrontmatterView.status`. Removing the local `Status` and importing `page_mod.Status` would eliminate the redundancy and the conversion burden.
4. **Add co-located tests for BOM, invalid UTF-8, YAML-form rejection, and unclosed fence**: Several rejection paths are structurally present but have no corresponding test block.
5. **Tighten the arena-protection assertion in the oversize-id test**: Adding `arena.queryCapacity()` assertions analogous to the title test would make the id-path protection as verifiable as the title path.
6. **Consider `errdefer` in `parseTagsList` for non-arena `retain`**: If callers ever pass a non-arena allocator as `retain`, partial tag allocation on error would not be reclaimed. A stricter function contract or a per-item cleanup path would make the function safe outside arena contexts.
