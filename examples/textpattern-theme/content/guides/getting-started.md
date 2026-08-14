---
title: Getting started
parent: guides
status: published
tags: [guides, build]
---

# Getting started

The theme is a directory of content plus a directory of layouts and assets.
The Boris binary joins them into page-relative HTML.

## Build the example

```bash
./bin/boris \
  --input REFERENCE/examples/textpattern-theme/content \
  --theme REFERENCE/examples/textpattern-theme/theme \
  --layout-rule default id:index theme/layouts/home.html \
  --layout-rule default id:guides theme/layouts/section.html \
  --layout-rule default id:reference theme/layouts/section.html \
  --layout-rule default id:blog theme/layouts/blog.html \
  --layout-rule default id:archive theme/layouts/archive.html \
  --layout-rule default 'glob:blog/*' theme/layouts/blog.html \
  --html-dir work/probe/textpattern-theme \
  --quiet
```

## Check the output

1. Open `index.html` and follow the generated site navigation.
2. Confirm that `guides.html` exposes its two direct children.
3. Open a blog entry and inspect its breadcrumb, metadata, and TOC.
4. Resize below the mobile breakpoint; no region should disappear.
5. Confirm the stylesheet and mark are under the generated `assets/` tree.

<Aside kind="warning">

Keep generated output under an ignored workspace directory. Do not use a
theme experiment to modify Boris or Oliver implementation code; unexpected
behavior should become a small, reproducible issue instead.

</Aside>
