---
title: Graph validation rules
parent: reference
status: published
tags: [reference, graph]
---

# Graph validation rules

HTML, IR, and RAG share the same Trunk / Satellite validation.

## Roles

| Condition | Role |
|-----------|------|
| No `parent` | **Trunk** |
| `parent: <trunk-id>` | **Satellite** |

## Hard failures (exit 1)

| Situation | Typical code |
|-----------|--------------|
| Parent id missing | `EMISSINGPARENT` / graph diagnostic |
| Parent is a Satellite | satellite-of-satellite |
| `parent` points at self | self-parent |
| Parent cycle | cycle diagnostics |
| Duplicate entity ids | `EDUPLICATEID` |

## One-level only

```text
Trunk ──► Satellite     OK
Satellite ──► Satellite NOT OK
```

Folder nesting does **not** create multi-level graph parents. See
[[guides/deep/nested/path/note]].

## Concepts

[[concepts/trunk-satellite]] · [[concepts/parent-keys]]
