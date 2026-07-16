---
title: Getting started
parent: guides
status: published
tags: [guides, onboarding]
---

# Getting started

Build this example from the Boris repository root with a release or
`zig-out` binary.

## Prerequisites

- Zig **0.16+** and a successful `zig build` (produces `./zig-out/bin/boris`)
- No Node, npm, Tailwind CLI, or network access during the site build

## Build the showcase

```bash
zig build

./zig-out/bin/boris \
  --input examples/static-theme-showcase/content \
  --theme examples/static-theme-showcase/theme \
  --layout-rule default id:index \
    examples/static-theme-showcase/theme/layouts/home.html \
  --layout-rule default 'glob:blog/*' \
    examples/static-theme-showcase/theme/layouts/blog.html \
  --layout-rule default role:trunk \
    examples/static-theme-showcase/theme/layouts/section.html \
  --html-dir test-output/static-theme-showcase \
  --quiet
```

## Expected artifacts

| Path | Notes |
|------|--------|
| `test-output/static-theme-showcase/index.html` | Home layout (`data-layout="home"`) |
| `…/guides/getting-started.html` | Default docs layout (`main`) |
| `…/blog/first-post.html` | Blog layout |
| `…/assets/css/showcase.css` | Theme CSS copied by `asset-url` |
| `…/assets/img/mark.svg` | Local mark |

Open `index.html` in a browser (or serve the directory statically). All CSS
and images resolve page-relatively with no external requests.

<Aside kind="note">

Keep HTML under an ignored path inside the repo (for example
`test-output/…`). Boris rejects workspace-escaping output roots.

</Aside>
