---
title: Parent keys
parent: concepts
status: published
tags: [concepts, frontmatter]
---

# Parent keys

Author frontmatter uses **one** parent key name:

```markdown
---
parent: guides
---
```

## Migration map

| Old name / habit | Boris action |
|------------------|--------------|
| `parent` | Keep |
| `parentEntry` | Rename to `parent` (unknown key fails) |
| `parent_entry` | Rename to `parent` (unknown key fails) |
| `parents: [a, b]` | Unsupported — pick one Trunk |
| Nested menu weight only | Encode hierarchy with `parent` + nav, not YAML trees |

RAG **export** may still label a catalog column `parent_entry` for the same
string. That is packaging, not author grammar.

## Checklist

1. Grep for `parentEntry` / `parent_entry` and rewrite.
2. Ensure every `parent` value is an existing **Trunk** entity id.
3. Recompile until exit 0.
