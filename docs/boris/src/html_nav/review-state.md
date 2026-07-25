---
title: "`src/html_nav.zig` review state"
id: docs/boris/src/html_nav/review-state
parent: docs/boris/src/html_nav
status: draft
tags: [boris, zig, source-reference, review-state, html_nav]
---

# `src/html_nav.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

The following are observations about gaps or design choices that could be addressed in future work. None of these represents an existing defect; they are speculative improvement candidates only.

1. **`renderChildren` ownership asymmetry.** The mixed return (literal `""` vs heap allocation) is unusual and callers must handle it specially. An alternative is to always return a heap allocation (including a zero-length one), or to split the API into a boolean "has children" guard and a separate render function.
2. **`outputPathFor` bypasses `identity.safeOutputRelativePath`.** The local helper `outputPathFor` constructs `"{id}.html"` without the entity-id validation gate present in `identity.safeOutputRelativePath`. Since `graph.validate` is a precondition, ids should always be valid at this point, but the dependency on that upstream contract is implicit rather than enforced. Replacing `outputPathFor` with a call to `identity.safeOutputRelativePath` would make the contract explicit at the cost of an additional allocation and error path.
3. **`current_index` bounds not checked in unsafe modes.** The functions index `nav[current_index]` and `nodes[current_index]` without a source-level bounds check. Safe and Debug builds will trap; ReleaseFast and ReleaseSmall will not. A compile-time-documented precondition or a debug assertion would make this explicit.
4. **`relativeHref` 32-component cap.** The fixed stack array in `identity.relativeHref` silently truncates paths with more than 32 directory components. `html_nav.zig` does not document or assert this limit. Asserting `nodes.len` constraints or documenting the maximum supported nesting depth would improve robustness.
5. **`siteNavMaterial` is not covered by any test in this file.** Its correctness is implicitly relied upon by any incremental-build cache that uses its output, but the function has no dedicated test asserting its exact byte output for a known input, only the structural guarantee implied by the format description in the module doc comment.
6. **`appendEscaped` does not handle `'` (single-quote).** For the current output format, where all HTML attributes use `"` delimiters, this is acceptable. If the output format ever changes to use single-quoted attributes, callers would need to update the escaping policy.
