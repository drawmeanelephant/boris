---
title: Wiki links
parent: guides
status: published
tags: [guides, linking]
---

# Wiki links

Boris resolves wiki links **before** Apex, using the frozen graph.

## Forms

```markdown
[[guides/getting-started]]
[[guides/getting-started|Getting started]]
[[guides/heading-fragments#hello-world]]
[[guides/heading-fragments#hello-world|Hello World section]]
```

## Live links in this fixture

- Page only: [[guides/getting-started]]
- Labeled: [[reference/cli|CLI reference]]
- Fragment: [[guides/heading-fragments#hello-world|Hello World]]
- Cross-trunk: [[index#migration-goals|Home · Migration goals]]
- From an include: {{include includes/wiki-from-include.md}}

## Rules migrants must keep

1. Target is the **entity id**, not a filesystem path with `.md`.
2. Case is **byte-exact** (`CaseDemo` ≠ `casedemo`).
3. Entity id characters in wiki syntax are ASCII (`A–Z a–z 0–9 / _ - .`).
4. Missing entity or heading → `EREFERENCEMISSING` (exit 1).
5. No rewrite inside **fenced** code blocks (examples stay literal). Inline
   backticks do **not** protect wiki syntax — put examples in fences.

## Related

[[guides/heading-fragments]] · [[reference/entity-ids]] · [[concepts/path-identity]]
