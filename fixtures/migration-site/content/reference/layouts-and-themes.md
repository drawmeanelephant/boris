---
title: Layouts and themes
parent: reference
status: published
tags: [reference, themes]
---

# Layouts and themes

This fixture ships a theme at `fixtures/migration-site/theme/`:

```text
theme/
  layouts/main.html
  footer.html
  assets/css/site.css
  assets/img/mark.svg
```

## CLI

```bash
# Sugar for --html-layout theme/layouts/main.html (+ managed assets)
./zig-out/bin/boris --theme fixtures/migration-site/theme ...
```

## Layout slots used here

| Marker | Purpose |
|--------|---------|
| `{{content}}` | Required body |
| `{{title}}` | Document title text |
| `{{nav}}` | Graph forest |
| `{{breadcrumb}}` | Root → current |
| `{{toc}}` | In-page h1–h3 outline |
| `{{metadata}}` | Closed frontmatter summary |
| `{{footer}}` | Theme `footer.html` |
| `{{asset-url assets/...}}` | Page-relative theme asset URL |

## Depth-correct CSS links

| Page output | Typical `site.css` href |
|-------------|-------------------------|
| `index.html` | `assets/css/site.css` |
| `guides/getting-started.html` | `../assets/css/site.css` |
| `guides/deep/nested/path/note.html` | `../../../../assets/css/site.css` |

Assets are **copied** into each HTML target; Boris does not fetch CDNs.
