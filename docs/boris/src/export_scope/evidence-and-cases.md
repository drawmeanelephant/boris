---
title: "`src/export_scope.zig` evidence and cases"
id: docs/boris/src/export_scope/evidence-and-cases
parent: docs/boris/src/export_scope
status: draft
tags: [boris, zig, source-reference, evidence, export_scope]
---

# `src/export_scope.zig` evidence and cases

## Behavioral invariants (directly demonstrated by tests)

The following properties are **directly demonstrated** by inline tests:

1. **Scope selects collection, closes parents, and expands semantic neighbors (one hop):**
A scope of `"mascots/child"` on a fixture with pages `mascots`, `mascots/child` (parent: `mascots`, has relation to `other`), `other` (has relation to `transitive`), and `transitive` yields exactly `[mascots, mascots/child, other]`. The transitive semantic neighbor `transitive` is *not* included, confirming that semantic closure is one hop.
2. **Scope rejects empty string, `..` prefix, traversal forms, and missing ids:**
`selectPages(..., "")`, `selectPages(..., "../mascots")`, and `selectPages(..., "missing")` all return `error.InvalidScope`.
3. **`partitionMarkdown` preserves fence integrity:**
A body containing a fenced code block with an internal blank line is not split inside the fence. A body with two fenced blocks and an intervening blank line may produce one or two parts, but each part contains either zero or two (matching) fence markers — no unclosed fence is produced.
4. **`partitionMarkdown` returns `error.OversizedBlock` on an indivisible block:**
A single paragraph with no blank lines that exceeds the budget returns `error.OversizedBlock`.
5. **`partitionMarkdown` splits correctly at paragraphs and headings:**
A body with two paragraphs separated by a blank line and an embedded fenced code block, given a budget of 55 bytes, produces parts each ≤ 55 bytes with matched fence counts.

***

## Inline tests

| Test name | Kind | Purpose | Key assertion |
| :-- | :-- | :-- | :-- |
| `scope selects collection and closes parents plus semantic neighbors` | Functional | Verify three-phase closure: seed + one-hop semantic + transitive parent | `selected.len == 3`; ids are `mascots`, `mascots/child`, `other` in order |
| `scope rejects empty and traversal selectors` | Rejection | Validate scope string guard | `error.InvalidScope` for `""`, `"../mascots"`, `"missing"` |
| `partition preserves fenced code and reports indivisible blocks` | Functional + error | Fence tracking; OversizedBlock path | All parts have even fence-marker counts; `error.OversizedBlock` for no-boundary input |
| `partition splits paragraphs and headings without cutting a fence` | Functional | Greedy split at blank/heading outside fence | `parts.len >= 1`; each part ≤ 55 bytes; even fence-marker count per part |


***

## Control flow: `selectPages`

```text
selectPages(allocator, pages, scope)
    │
    ├─ scope == null → allocate copy of all pages → return
    │
    ├─ validate scope string
    │   ├─ empty, starts with '.', contains '..', contains '/' → error.InvalidScope
    │
    ├─ Phase 1: seed scan over pages
    │   ├─ id == scope OR (id starts with scope AND id[scope.len] == '/') → included[i]=true, seed[i]=true
    │   └─ no match found → error.InvalidScope
    │
    ├─ Phase 2: semantic neighbor expansion
    │   └─ for each seeded page, for each semanticRelation,
    │      scan all candidates for id == relation.target → included[j]=true
    │
    ├─ Phase 3: transitive parent closure (loop until !changed)
    │   └─ for each included page with .parent,
    │      scan candidates for id == parent → included[j]=true; changed=true
    │
    └─ collect included pages in order → toOwnedSlice → return
```

## Control flow: `partitionMarkdown`

```text
partitionMarkdown(allocator, body, max_body)
    │
    ├─ body.len <= max_body → return single-element slice [body]
    ├─ max_body == 0 → error.OversizedBlock
    │
    └─ greedy loop: start=0
        │
        ├─ remaining fits → append body[start..] → break
        │
        └─ scan body[start .. start+max_body] line by line
            │
            ├─ per line: update fence state (fenceLine → open/close)
            │
            ├─ if fenceChar==0 AND lineEnd <= limit:
            │   ├─ blank line → lastBoundary = lineEnd
            │   └─ heading    → lastBoundary = cursor (heading starts next piece)
            │
            ├─ no boundary found → error.OversizedBlock
            ├─ boundary == start → error.OversizedBlock
            │
            └─ append body[start..boundary] → start = boundary → continue
```


***
