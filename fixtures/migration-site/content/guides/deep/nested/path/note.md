---
title: Deep nested path note
parent: guides
status: published
tags: [guides, paths]
---

# Deep nested path

This page lives at:

```text
content/guides/deep/nested/path/note.md
```

Path-derived entity id:

```text
guides/deep/nested/path/note
```

HTML output path:

```text
guides/deep/nested/path/note.html
```

## Migration lesson

Deep folders are fine. **Graph depth is not folder depth:** this Satellite’s
`parent` is still the Trunk `guides`, never another Satellite. Nested
satellites of satellites fail validation.

## Links

- Parent trunk: [[guides]]
- Sibling: [[guides/getting-started]]
- Fragment home: [[index#migration-goals]]
