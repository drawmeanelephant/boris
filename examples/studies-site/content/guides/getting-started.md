---
title: Getting started
parent: guides
status: published
tags: [guides, onboarding]
---

# Getting started

Build this specimen from the Boris repository root after a successful
`zig build`. One content tree, six shipped themes. Swap `--theme`.

## Prerequisites

- Zig **0.16+**
- `./zig-out/bin/boris` from `zig build`
- No Node, npm, or network access for the site build

## Full HTML build

```bash
THEME=semantic   # or columns, service, engineering, civic, tokens

./zig-out/bin/boris \
  --input examples/studies-site/content \
  --theme themes/$THEME \
  --layout-rule default id:index \
    themes/$THEME/layouts/home.html \
  --layout-rule default role:trunk \
    themes/$THEME/layouts/section.html \
  --html-dir test-output/$THEME \
  --quiet
```

## Expected artifacts

| Path | Layout / notes |
|------|----------------|
| `test-output/<theme>/index.html` | `data-layout="home"` |
| `…/guides.html`, `…/reference.html` | `data-layout="section"` |
| `…/guides/getting-started.html` | `data-layout="main"` |
| `…/assets/css/<theme>.css` | theme asset copy |
| `…/index.assets/rhythm-diagram.svg` | page-local asset |

## Verify offline output

```bash
# Should print nothing
rg -n 'https?://' test-output/semantic --glob '*.html' || true
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
