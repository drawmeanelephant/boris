---
title: Frontmatter Reference
status: published
tags: [reference, authoring]
---
# Frontmatter Reference

Boris uses a strictly validated, closed set of frontmatter keys. Any unknown keys (like `parentEntry`) will result in an `EFRONTMATTER` compiler error.

## Allowed Keys

| Key | Type | Description |
|-----|------|-------------|
| `id` | String | Optional override for the entity ID. Defaults to file path. |
| `title` | String | The page title. (Required) |
| `parent` | String | The entity ID of the parent Trunk page. (Required for Satellites) |
| `status` | String | Must be `published`, `draft`, or `archived`. |
| `tags` | List | Standard YAML list format: `[a, b, c]`. |

## Examples

### Trunk Page

```yaml
---
title: My Guide Overview
status: published
tags: [guides]
---
```

### Satellite Page

```yaml
---
title: Detailed Topic
parent: guides/overview
status: published
---
```
