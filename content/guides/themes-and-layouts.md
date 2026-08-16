---
title: Themes & Layouts
parent: guides/overview
status: published
tags: [guides, themes, layouts, css]
---

<p class="eyebrow">Presentation</p>

# Themes & Layouts {#themes-and-layouts}

Boris layouts are plain HTML files with marker tokens. This guide explains how to use an existing theme, create your own layout, and manage CSS assets.

> A theme is trusted static HTML and copied bytes. It is not a component
> runtime, and it is not allowed to invent a second Markdown parser.

<Aside kind="note" id="css-eats-dom">

The default theme styles asides, details, definition lists, footnotes,
tables, blockquotes, strikethrough, and content-local images. Write those
constructs if you want the CSS to have something to hold.

</Aside>

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

Shipped themes live under `themes/`. The default is `themes/boris`. Also
shipped: `reference`, `press`, `showcase`, `archive`, `field-notes`,
`compact`, `cards`, `cozy`, `journal`, `ledger`, `reading`, `semantic`,
`columns`, `service`, `engineering`, `civic`, and `tokens`. Sample sites
are under `examples/`. The catalog bar is `themes/README.md` in the
repository.

</Aside>

## Layout markers

Boris splices content into your layout by replacing **marker tokens**. All markers are optional except `{{content}}`:

| Marker | What it inserts |
|---|---|
| `{{content}}` | **Required.** The rendered HTML body of the current page |
| `{{title}}` | The page title, or entity id when title is absent |
| `{{nav}}` | Full site navigation tree as nested `<ul>` lists |
| `{{breadcrumb}}` | Breadcrumb trail from root to current page |
| `{{toc}}` | In-page table of contents from `h1`–`h3` headings |
| `{{children}}` | Direct children of the current page |
| `{{metadata}}` | Escaped Boris metadata for the current page |
| `{{relations}}` | Outgoing validated semantic relations, or empty |
| `{{backlinks}}` | Incoming semantic relations, or empty |
| `{{footer}}` | Optional layout footer fragment loaded from the theme's `footer.html` file |
| `{{head}}` | Compiler-owned head tags (Standard.site / Nostr verification). Empty when unused. |
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

The search root attribute on `<main>` tells Boris's compiler-owned search
producer to index the content inside this element and exclude navigation. The
default theme also includes the small browser consumer; a custom theme can
ship its own consumer or provide a no-JavaScript fallback.

`footer.html` is optional theme-owned static HTML inserted by `{{footer}}`.
`{{metadata}}` emits the page's closed Boris metadata with escaped values.
Neither marker turns a layout into a template language: layouts have no loops,
conditionals, expressions, or component runtime.

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

<Details summary="What a layout is not">

No loops. No conditionals. No expressions. No MDX. Eleven closed slots plus
`{{asset-url}}`. If you wanted Jinja, you wanted a different compiler.

</Details>

## Next steps

- [[guides/search-and-ui|Search & Browser UI]] — adding search to your custom layout
- [[guides/oliver-markdown|Markdown Showcase]] — the body constructs your CSS should expect
- [[reference/commands|Command Reference]] — all `--theme`, `--layout-rule`, and `--target` flags
