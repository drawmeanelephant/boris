# Gallery

Image-first theme for photo galleries and small portfolios. Pale gallery
wall, dark ink, museum-label captions, and a grid index of albums. In dark
mode the wall turns charcoal and the images stay as they are. It is a
Boris-owned design with no upstream theme.

- Layouts: `home` (album grid via `{{children}}`), `main` (album or single image)
- Assets: `assets/css/gallery.css`
- Fonts: system serif for prose, system UI sans for labels, UI mono for
  code. No shipped webfont.
- Footer: `footer.html` (one static line)
- Sample site: [`examples/gallery-site/`](../../examples/gallery-site/)
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)

```bash
./zig-out/bin/boris \
  --input examples/gallery-site/content \
  --theme themes/gallery \
  --layout-rule default id:index themes/gallery/layouts/home.html \
  --html-dir test-output/gallery \
  --quiet
```

In a publication profile, the same selection is a `layout_rules` entry
`{"selector": "id:index", "layout": "themes/gallery/layouts/home.html"}`.

## Named layouts

| Layout | Use for | Shape |
|---|---|---|
| `main.html` | Albums, single-image pages, anything else (fallback) | Breadcrumb header, subject tags, wide content wall, wall label (parent link + metadata), "In this room" child grid, relations/backlinks, site index |
| `home.html` | The index (`id:index`) or any landing page | Wordmark header, subject tags, intro content, "Albums" child grid, metadata, relations/backlinks, site index |

## Slot coverage

| Slot | `main` | `home` | Notes |
|---|:-:|:-:|---|
| `{{content}}` | yes | yes | Inside `.prose` |
| `{{title}}` | yes | yes | `<title>` only; the page's own `# heading` is the visible title |
| `{{head}}` | yes | yes | Compiler-owned head output |
| `{{asset-url}}` | yes | yes | `assets/css/gallery.css` |
| `{{page-status}}` | yes | yes | `<body data-status>`; `draft` shows a Draft badge |
| `{{breadcrumb}}` | yes | no | The index is the root, so a one-item trail adds nothing |
| `{{children}}` | yes | yes | The grid: each child is a numbered mat tile |
| `{{metadata}}` | yes | yes | Wall label below the content |
| `{{tags}}` | yes | yes | Subject chips above the title |
| `{{parent}}` | yes | no | A back link in the wall label. Trunks emit nothing |
| `{{relations}}` | yes | yes | "See also" |
| `{{backlinks}}` | yes | yes | "Referenced by" |
| `{{nav}}` | yes | yes | In a native `<details>` "Site index" in the footer |
| `{{footer}}` | yes | yes | `footer.html` |
| `{{toc}}` | no | no | Omitted on purpose: gallery pages are short and image-led, and an outline of three headings competes with the pictures. Use a text theme for long prose |

Empty regions are hidden with `:has()`, so a page without children,
relations, or metadata does not show an empty band.

**Tags appear twice.** The frozen `{{metadata}}` `<dl>` still includes a
`Tags` row, and the theme cannot single it out with CSS. The chips above the
title are for scanning; the wall label is the colophon.

## Images and figures

Boris has no image processing. It copies `{stem}.assets/` files byte for
byte and rewrites Markdown image URLs to page-relative paths. Scale and
compress images before you commit them; the theme only sizes and frames
them.

- A bare `img` is block-level, never wider than its column, and never
  taller than 85% of the viewport. Portrait images therefore stay on screen.
- For a caption, wrap a Markdown image in raw `<figure>` HTML and keep the
  blank lines so the image is still Markdown and still rewritten:

  ```markdown
  <figure>

  ![Alt text describing the picture](album.assets/plate.png)

  <figcaption><strong>Plate.</strong> Caption text.</figcaption>
  </figure>
  ```

- To lay out several figures as a grid, wrap them in
  `<div class="gallery-grid">` … `</div>` with blank lines around each
  figure. The grid fills columns of at least 18rem and stacks on narrow screens.
- `srcset`, `sizes`, and `<picture>` are up to you. Raw `<img>` is not
  rewritten or checked by Boris, so write those URLs page-relative by hand.

The `.prose` column covers Aside (all five kinds), Details, tables (scroll
horizontally), definition lists, footnotes, inline and fenced code, and
blockquotes.

## Search

Search is not included. A gallery is small and you browse it by sight: the
album grid, breadcrumb, parent link, and footer site index are how readers
find things. Adding the first-party search consumer would put roughly 80
lines of inline JavaScript (the size of the `boris` theme's consumer) on
every page of a theme that otherwise ships none. `<main>` still carries
`data-boris-search-root` and the chrome regions carry
`data-boris-search-exclude`, so the compiler's
`_boris/search/search-index.json` indexes captions and prose correctly. A
later layout can add the inline consumer without changing any markup.

## Provenance

Original to Boris. The "wall, mat, and label" vocabulary borrows from museum
hanging conventions in general, not from any particular site or theme. No
third-party CSS, fonts, images, or JavaScript are shipped.
