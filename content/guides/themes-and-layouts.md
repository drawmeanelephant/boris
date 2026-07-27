---
title: Themes & Layouts
parent: guides/overview
status: published
tags: [guides, themes, layouts, css]
---

# Themes & Layouts

Boris layouts are plain HTML files with marker tokens. This guide explains how to use an existing theme, create your own layout, and manage CSS assets.

## What a theme is

A theme is a directory with this structure:

```text
my-theme/
  layouts/
    main.html       # required — the main HTML layout
  assets/
    theme.css       # any assets you want copied to the output
```

Boris copies the `assets/` folder into the output directory at `assets/` automatically. You can put CSS, fonts, images, or any other static files there.

## Using a theme

Point Boris at your theme directory with `--theme`:

```bash
./zig-out/bin/boris --theme my-theme --html-dir dist
```

`--theme ROOT` is shorthand for `--html-layout ROOT/layouts/main.html`. Boris derives the asset root from the layout path.

To use a layout directly without the theme shorthand:

```bash
./zig-out/bin/boris --html-layout my-theme/layouts/main.html --html-dir dist
```

<Aside kind="tip">

The repository includes several ready-made themes under `examples/`:
- `examples/prototype-corporate` — Corporate documentation style
- `examples/prototype-minimalist` — Clean minimal style
- `examples/agent-themes/pure/theme` — Pure CSS, no framework
- `examples/agent-themes/chota/theme` — Chota micro-framework

</Aside>

## Layout markers

Boris splices content into your layout by replacing **marker tokens**. All markers are optional except `{{content}}`:

| Marker | What it inserts |
|---|---|
| `{{content}}` | **Required.** The rendered HTML body of the current page |
| `{{title}}` | The page title from frontmatter |
| `{{nav}}` | Full site navigation tree as nested `<ul>` lists |
| `{{breadcrumb}}` | Breadcrumb trail from root to current page |
| `{{toc}}` | In-page table of contents from `h1`–`h3` headings |
| `{{footer}}` | Optional layout footer fragment loaded from the theme's `footer.html` file |
| `{{asset-url PATH}}` | Path to a theme asset, adjusted for the current page depth |

## Referencing assets in your layout

Use `{{asset-url}}` to reference assets from your layout without hardcoding path depth:

```html
<link rel="stylesheet" href="{{asset-url assets/theme.css}}">
```

Boris replaces `{{asset-url assets/theme.css}}` with the correct relative path from the current page's location to the asset. A page at `guides/building-pages.html` gets `../assets/theme.css`; a page at `index.html` gets `assets/theme.css`.

## Minimal layout example

This is the minimum layout Boris requires:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{title}} · My Docs</title>
  <link rel="stylesheet" href="{{asset-url assets/theme.css}}">
</head>
<body>
  <aside>{{nav}}</aside>
  <main data-boris-search-root>{{content}}</main>
</body>
</html>
```

The search root attribute on `<main>` is important if you plan to use the search indexer — it tells Boris's search extractor to index the content inside this element and exclude navigation.

## Per-page layout rules

You can assign different layouts to different pages using `--layout-rule`:

```bash
./zig-out/bin/boris \
  --theme my-theme \
  --layout-rule default id:index my-theme/layouts/home.html \
  --layout-rule default role:trunk my-theme/layouts/section.html \
  --html-dir dist
```

Layout rule selectors:

| Selector | Matches |
|---|---|
| `id:ENTITY_ID` | The page with that exact entity id |
| `role:trunk` | All Trunk pages |
| `role:satellite` | All Satellite pages |
| `glob:PATTERN` | Pages whose entity id matches the glob pattern |

Layout selection precedence follows explicit resolution rules: exact `id:` matches take highest priority, followed by specific `glob:` patterns, role fallbacks (`role:trunk` / `role:satellite`), and target default layout fallbacks. Declaration order does not alter selection precedence. The `--theme` flag sets the default layout; rules override it selectively.

## Multiple output targets

Build separate output directories in one command using `--target`:

```bash
./zig-out/bin/boris \
  --target docs=dist/docs \
  --target api=dist/api \
  --target-layout docs=themes/docs/layouts/main.html \
  --target-layout api=themes/api/layouts/main.html
```

Each target is isolated — it has its own output directory, layout, and asset set. This lets you publish different presentations of the same content tree in one build.

## Next steps

- [[guides/search-and-ui|Search & Browser UI]] — adding search to your custom layout
- [[reference/commands|Command Reference]] — all `--theme`, `--layout-rule`, and `--target` flags
