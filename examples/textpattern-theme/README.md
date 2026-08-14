# Textpattern theme for Boris

This is a first-class Boris theme example translated from the visual language
of the legacy Textpattern reference files in [`REFERENCE/rk/`](../../rk/).
It keeps the original's paper, crimson, slate, serif, sans, and monospace
character while using Boris-native Markdown, graph navigation, layout rules,
managed assets, and closed content components.

The legacy files remain untouched. They use a different template dialect:
`$title$`, `$description$`, `$body$`, and `$assets_root$`. This folder is the
Boris port and should be treated as the candidate for an eventual theme
option, replacement example, or codeless PR.

## What this example exercises

| Boris surface | Where to inspect it |
|---|---|
| Home, section, blog, archive, and fallback layouts | `theme/layouts/` and the build rules below |
| Core layout slots | every layout uses `{{title}}`, `{{content}}`, `{{nav}}`, `{{breadcrumb}}`, `{{toc}}`, `{{children}}`, `{{metadata}}`, and `{{footer}}` |
| Semantic shell | fallback pages expose generated navigation, metadata, children, and native disclosure |
| Trunk/Satellite graph | `content/index.md`, the `guides/`, `reference/`, `blog/`, and `archive/` trees |
| CommonMark surfaces | tables, links, lists, code, blockquotes, raw HTML, `Aside`, and `Details` |
| Theme-owned and page-local assets | `theme/assets/` and `content/index.assets/press-cycle.svg` |
| Responsive and accessible chrome | `theme/assets/css/textpattern.css` and `ACCESSIBILITY.md` |
| Offline output | no CDN, remote font, JavaScript, framework, or network image |

## Build

From the workspace root, using the supplied Boris binary:

```bash
./bin/boris \
  --input REFERENCE/examples/textpattern-theme/content \
  --theme REFERENCE/examples/textpattern-theme/theme \
  --layout-rule default id:index \
    REFERENCE/examples/textpattern-theme/theme/layouts/home.html \
  --layout-rule default id:guides \
    REFERENCE/examples/textpattern-theme/theme/layouts/section.html \
  --layout-rule default id:reference \
    REFERENCE/examples/textpattern-theme/theme/layouts/section.html \
  --layout-rule default id:blog \
    REFERENCE/examples/textpattern-theme/theme/layouts/blog.html \
  --layout-rule default id:archive \
    REFERENCE/examples/textpattern-theme/theme/layouts/archive.html \
  --layout-rule default 'glob:blog/*' \
    REFERENCE/examples/textpattern-theme/theme/layouts/blog.html \
  --html-dir work/probe/textpattern-theme \
  --quiet
```

The selectors are deliberately disjoint: exact IDs handle the five landing
pages, the blog glob handles only blog Satellites, and the fallback
`main.html` handles the remaining guide, reference, and archive entries. This
keeps the theme easy to audit even though the refreshed binary now produces
the same result for overlapping rules in either declaration order; the
precedence clarification is recorded as resolved in
[Boris issue #400](https://github.com/drawmeanelephant/boris/issues/400).

## Theme map

```text
textpattern-theme/
  README.md
  ACCESSIBILITY.md
  MIGRATION.md
  published-pages.txt
  content/
    index.md + index.assets/press-cycle.svg
    guides.md + guides/{getting-started,components}.md
    reference.md + reference/slots.md
    blog.md + blog/{first-post,second-post}.md
    archive.md + archive/{001-first-roll,040-night-bus,120-last-light}.md
  theme/
    layouts/{main,home,section,blog,archive}.html
    footer.html
    assets/css/textpattern.css
    assets/img/textpattern-mark.svg
```

## Design intent

The port is intentionally not a pixel-perfect copy of an old Textpattern
site. It preserves the strongest cues—editorial serif reading, a dark
masthead, crimson links, quiet rules, paper surfaces, compact metadata, and a
sidebar that becomes a stacked reading flow—then gives each Boris slot a
stable semantic home. The layout remains static HTML and CSS; native
`<details>` is used for disclosure, not a JavaScript imitation.

## Verification

After building, inspect the generated output rather than the source boundary:

```bash
find work/probe/textpattern-theme -type f | sort
rg -n 'data-layout=|site-nav|page-toc|page-children|page-metadata|admonition|details' \
  work/probe/textpattern-theme --glob '*.html'
rg -n 'https?://|<script|@import' \
  work/probe/textpattern-theme --glob '*.html' --glob '*.css' || true
```

The final command should produce no generated-site matches. Any unexpected
compiler or renderer behavior belongs in a reproducible Boris or Oliver issue;
do not repair the binaries from this example.

For the standalone search-index binary, pass an exact list of published pages
when the output directory also contains compiler proof artifacts:

```bash
./bin/boris-search-index \
  --root work/probe/textpattern-theme \
  --out work/probe/textpattern-search \
  --pages-file REFERENCE/examples/textpattern-theme/published-pages.txt \
  --require-root-marker \
  --quiet
```

The refreshed candidate produces 13 indexed live pages. The page list keeps
`_boris/proof/index.html` out of the standalone audit; that internal proof page
does not carry the published-page search-root marker.
