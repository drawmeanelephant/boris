---
title: Getting started
parent: guides
status: published
tags: [guides, onboarding]
---

# Getting started

Build this example from the Boris repository root after a successful
`zig build`.

## Prerequisites

- Zig **0.16+**
- `./zig-out/bin/boris` from `zig build`
- No Node, npm, Tailwind CLI, or network access for the site build

## Full HTML build

```bash
./zig-out/bin/boris \
  --input examples/reference-theme/content \
  --theme examples/reference-theme/theme \
  --layout-rule default id:index \
    examples/reference-theme/theme/layouts/home.html \
  --layout-rule default role:trunk \
    examples/reference-theme/theme/layouts/section.html \
  --html-dir test-output/reference-theme \
  --quiet
```

## Expected artifacts

| Path | Layout / notes |
|------|----------------|
| `test-output/reference-theme/index.html` | `data-layout="home"` |
| `…/guides.html`, `…/reference.html` | `data-layout="section"` |
| `…/guides/getting-started.html` | `data-layout="main"` |
| `…/assets/css/reference.css` | theme asset copy |
| `…/index.assets/rhythm-diagram.svg` | page-local asset |

## Verify offline output

```bash
# Should print nothing
rg -n 'https?://' test-output/reference-theme --glob '*.html' || true
```

<Aside kind="warning">

Keep generated HTML under an ignored path inside the workspace (for example
`test-output/…`). Do not commit build products.

</Aside>

## Reading this page

The docs layout (`main`) places:

1. **Browse** — full graph `{{nav}}` with the current page marked
2. **Article** — rendered Markdown, components, and optional `{{children}}`
3. **On this page** — heading outline from `{{toc}}`
