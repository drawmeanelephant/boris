---
title: Getting started
parent: guides
status: published
tags: [guides, onboarding]
---

# Getting started

Build the compiler once, then let the example's local theme own the HTML
shell. No Node, npm, CDN, or network access is needed for the publish step.

## Compile the site

```bash
zig build
./zig-out/bin/boris \
  --input examples/agent-themes/pure/content \
  --theme examples/agent-themes/pure/theme \
  --layout-rule default id:index examples/agent-themes/pure/theme/layouts/home.html \
  --layout-rule default role:trunk examples/agent-themes/pure/theme/layouts/section.html \
  --html-dir test-output/agent-themes/pure \
  --quiet
```

## Expected shape

| Output | Why it matters |
| --- | --- |
| `index.html` | Hero layout with graph children |
| `guides.html`, `reference.html` | Section layout with direct children |
| `guides/getting-started.html` | Main layout with nav, metadata, and TOC |
| `assets/pure-field-notes.css` | Theme-owned local asset |

<Aside kind="warning">

Keep generated output under an ignored path such as `test-output/`. The theme
source belongs under this example; generated HTML does not.

</Aside>

## Check the offline boundary

```bash
rg -n 'https?://|<script|@import|url\(' \
  test-output/agent-themes/pure --glob '*.html' --glob '*.css' || true
```

The compiled site should contain no remote stylesheets, scripts, imports, or
font/image URLs. Open the generated `index.html` locally to inspect the wide
and narrow layouts.
