# Semantic

**A landmark-first documentation theme: the page's structure is the surface.
Landmarks, heading levels, and native components are labelled where they
stand, so the rendered page reads like the outline it already is.**

Not "class-light docs with an accent colour". The banner, the main region, the
article, each section, the outline, and the footer name themselves in a small
monospace label; every heading carries its level in the left margin; callouts,
disclosure, tables, and definition lists are the platform elements, styled in
place. The layout authors no heading of its own, so a page has exactly one
`<h1>` — the one the content provides.

Hand-authored local CSS and system fonts. No dependencies, JavaScript, remote
assets, or new author grammar. Light and dark palettes follow the operating
system; `prefers-reduced-motion` pins scroll behavior off; print drops the
labels and the rails.

- Layouts: `layouts/home.html` (`id:index`), `layouts/section.html`,
  `layouts/main.html`
- Stylesheet: [`assets/css/semantic.css`](assets/css/semantic.css)
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)
- Specimen: [`specimen/content/`](specimen/) — theme-owned pages that teach
  landmarks, heading hierarchy, and native components.
- Shared corpus (still supported): [`examples/studies-site/`](https://github.com/drawmeanelephant/boris/tree/main/examples/studies-site/)

## Build the specimen

The specimen is a small, complete content graph: a home page, two section
landings, and four satellite pages. It is ordinary Boris Markdown under
`themes/semantic/specimen/content/`, so it is built directly — no extraction
step, and nothing outside this theme is touched.

```bash
./zig-out/bin/boris \
  --input themes/semantic/specimen/content \
  --theme themes/semantic \
  --layout-rule default id:index themes/semantic/layouts/home.html \
  --layout-rule default id:landmarks themes/semantic/layouts/section.html \
  --layout-rule default id:patterns themes/semantic/layouts/section.html \
  --html-dir test-output/semantic \
  --quiet
```

For live preview, use the same arguments with `boris watch --serve --port 8090`
instead of a one-shot build, then open the printed loopback URL.

The layouts also still style the shared `examples/studies-site/` corpus with
`--layout-rule default role:trunk themes/semantic/layouts/section.html` for its
section trunks. The theme's own specimen is the one that shows its voice.

## Named layouts

- `home.html` is a contents page. It renders the index prose, then the graph's
  first level as a two-column deck of real child links. No hero card.
- `section.html` is a landing page. It leads with the section prose and then
  its child pages.
- `main.html` is one document: breadcrumb, prose, optional children, graph
  links, and a metadata record at the foot. It is the fallback for every page
  without a named rule.

## Slot coverage

Every layout carries `{{content}}`, `{{title}}`, `{{nav}}`, `{{toc}}`,
`{{children}}`, `{{metadata}}`, `{{relations}}`, `{{backlinks}}`, `{{footer}}`,
and `{{head}}`. `{{breadcrumb}}` appears on `main` and `section`; the home page
is a root Trunk, where it is empty, so it is intentionally absent there.

Intentionally absent:

- `{{tags}}` — `{{metadata}}` already prints Tags in the foot record. A second
  per-tag list would repeat it.
- `{{parent}}` — `{{breadcrumb}}` already links the parent on `main` and
  `section`.
- `{{page-status}}` — Status is already text in the `{{metadata}}` record; the
  theme has no badge chrome that would add anything.

All navigation, the outline, the children list, and the graph links are
excluded from rendered search (`data-boris-search-exclude`); only the author
prose and the content's own headings are indexed.

## One heading per page

The layout puts `{{title}}` in the document `<title>` and authors no `<h1>`.
The page's Markdown supplies the single `<h1>`, so a rendered page never has
two. Because the document `title` resolves from the authored heading first and
the `<title>` element second
([rendered-search.md](../../docs/contracts/rendered-search.md)), a page with no
authored heading still indexes under its own frontmatter title.

## Reading the labels

The region labels (`<header>`, `<main>`, `<article>`, `<section>`, `<nav>`,
`<footer>`) and the heading-level labels (`h1`–`h6`) are CSS generated content.
They are annotations of the markup, not extra elements: the published HTML
contains only the semantic elements themselves. See
[`ACCESSIBILITY.md`](ACCESSIBILITY.md) for how the labels are kept out of the
way of assistive technology.

## Boundaries

Presentation only. No new slots, layout rules, frontmatter keys, dependencies,
font files, or JavaScript. The specimen is author content that demonstrates the
theme; it is not a component, a config schema, or a product build stage.
