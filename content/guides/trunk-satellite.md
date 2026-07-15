---
title: Trunk and Satellite Pages
parent: guides/overview
status: published
tags: [graph, content]
---
# Trunk and Satellite Pages

The core of Boris's content architecture is the distinction between **Trunks** and **Satellites**.

## Trunks

A Trunk page is a top-level node in the documentation graph.
- **Identification:** Omit the `parent` key in the frontmatter.
- **Example:** `content/guides/overview.md` is a Trunk.

## Satellites

A Satellite page is a child node that logically belongs to a Trunk.
- **Identification:** Must contain a `parent` key pointing to a valid Trunk's entity ID.
- **Entity IDs:** Entity IDs are derived from the file path minus the extension (e.g., `guides/overview`).

<Aside kind="warning">
**Validation Rules (Hard Errors):**
- No satellite-of-satellite (Satellites must point directly to Trunks).
- No missing parents (A parent ID must exist).
- No cycles.
</Aside>

### Example Frontmatter

```yaml
---
title: My Satellite Page
parent: guides/overview
status: published
---
```
