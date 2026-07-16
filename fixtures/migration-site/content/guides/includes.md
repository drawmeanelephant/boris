---
title: Includes
parent: guides
status: published
tags: [guides, includes]
---

# Includes

Share Markdown fragments without turning them into graph nodes.

## Syntax

```markdown
{{include includes/shared-callout.md}}
```

## Live includes

{{include includes/shared-callout.md}}

Nested include chain:

{{include includes/nested-tip.md}}

## Layout recommendations

| Location | Discovered as page? |
|----------|---------------------|
| `content/includes/**` | **No** (content-root `includes/` is skipped) |
| `content/guides/includes/**` | **Yes** if files end in `.md` / `.mdx` |

Prefer the content-root `includes/` tree for fragments.

## Failure modes

| Problem | Diagnostic |
|---------|------------|
| Missing file | `EINCLUDEMISSING` |
| Include cycle / depth | `EINCLUDECYCLE` |
| Illegal path (`..`, `\`) | `EINVALIDPATH` / syntax |

Includes contribute to the including page’s HTML fingerprint — edit a fragment
and `--incremental` rebuilds dependents.
