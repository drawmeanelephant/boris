---
title: Rename and move checklist
parent: cookbook
status: published
tags: [cookbook, rename]
---

# Rename and move checklist

Use this when changing paths or entity ids after the first green build.

## Before

1. Inventory current entity ids (`graph.json` pages or wiki targets).
2. List inbound wiki links and `parent:` references.
3. Decide whether the **path** moves, the **`id:`** overrides, or both.

## During

1. Move/rename the Markdown file (path-derived id follows the path).
2. Or set `id: old-id` temporarily to keep wiki targets stable while paths move.
3. Update every `parent:` that pointed at a renamed Trunk.
4. Update every wiki link (page and heading forms).
5. Update includes only if fragment paths moved.

```markdown
<!-- examples of forms to search/replace after a rename -->
[[guides/old-name]]
[[guides/old-name#section]]
parent: old-trunk
```

## After

1. Full HTML build (no incremental) — expect exit **0**.
2. Grep the tree for the old id string; expect zero hits outside history.
3. Open a few deep pages and confirm CSS still resolves (theme asset-url).
4. Optional IR: confirm `graph.json` node set.
5. Re-enable `--incremental` for daily edits.

## Failure signals

| Symptom | Likely cause |
|---------|--------------|
| Exit 1 `EREFERENCEMISSING` | Stale wiki target or heading fragment |
| Exit 1 missing parent | Stale `parent:` after Trunk rename |
| Exit 1 duplicate id | Path and override collide |
| Broken CSS on deep pages | Hand-written relative URLs; use asset-url |
