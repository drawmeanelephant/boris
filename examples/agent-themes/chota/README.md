# Chota-inspired Boris theme prototype

This is an independent Boris example for a compact documentation surface. It
borrows the visual direction of [Chota](https://jenil.github.io/chota/): small
type, a light 12-column layout vocabulary, restrained borders, semantic HTML,
CSS variables, compact navigation, and a responsive single-column fallback.

The implementation is original. It does not copy Chota's stylesheet or markup,
does not add Chota, a CDN, npm, JavaScript, or a runtime dependency, and is not
part of Boris's product chrome. `theme/assets/css/chota.css` is a small,
hand-authored static adaptation for this example only; Boris copies it into the
generated site through `{{asset-url …}}`.

## What is demonstrated

- A Trunk / Satellite content graph with local Markdown and `<Aside>` content.
- The closed Boris layout slots: `title`, `nav`, `breadcrumb`, `toc`,
  `metadata`, `children`, `content`, `footer`, and `asset-url`.
- Two static page layouts: a compact home landing page and a three-column
  reading shell selected by `--layout-rule`.
- A small responsive grid, native controls, visible keyboard focus, dark-mode
  variables, and reduced-motion handling without JavaScript.
- Only page-relative local output; no remote fonts, images, stylesheets, or
  scripts.

## Tree

```text
examples/agent-themes/chota/
  README.md
  content/
    index.md
    guides.md
    guides/getting-started.md
    reference.md
    reference/slots.md
  theme/
    layouts/home.html
    layouts/main.html
    assets/css/chota.css
    footer.html
```

## Build

From the repository root, after building Boris:

```bash
zig build

./zig-out/bin/boris \
  --input examples/agent-themes/chota/content \
  --theme examples/agent-themes/chota/theme \
  --layout-rule default id:index \
    examples/agent-themes/chota/theme/layouts/home.html \
  --html-dir test-output/agent-themes-chota \
  --quiet
```

The output should contain `index.html`, `guides.html`,
`guides/getting-started.html`, `reference.html`,
`reference/slots.html`, and `assets/css/chota.css`. Open
`test-output/agent-themes-chota/index.html` or serve that directory with any
static file server. The generated site is self-contained.

Useful checks:

```bash
rg -n 'data-layout=|site-nav|page-toc|page-children|admonition--' \
  test-output/agent-themes-chota --glob '*.html'

# No network resources are allowed in this example.
rg -n 'https?://' test-output/agent-themes-chota --glob '*.html' || true
```

## Determinism proof

The output is intentionally safe to rebuild into the same directory. To prove
the two complete compiles are byte-identical, hash every non-cache file after
each run:

```bash
OUT=test-output/agent-themes-chota
rm -rf "$OUT" "$OUT".boris-stage

run() {
  ./zig-out/bin/boris \
    --input examples/agent-themes/chota/content \
    --theme examples/agent-themes/chota/theme \
    --layout-rule default id:index \
      examples/agent-themes/chota/theme/layouts/home.html \
    --html-dir "$OUT" \
    --quiet
}

run
find "$OUT" -type f ! -path '*/.boris-cache/*' -print0 | sort -z \
  | xargs -0 shasum -a 256 > /tmp/chota-theme-a.sha
run
find "$OUT" -type f ! -path '*/.boris-cache/*' -print0 | sort -z \
  | xargs -0 shasum -a 256 > /tmp/chota-theme-b.sha
diff -u /tmp/chota-theme-a.sha /tmp/chota-theme-b.sha
```

An empty diff is the acceptance signal. Generated output belongs under the
ignored `test-output/` directory and is not committed.

## Accessibility notes

The layout uses `header`, named `nav`, `main`, `article`, `aside`, and
`footer` landmarks; a skip link moves keyboard users to the article; focus
rings are visible and high contrast; links remain underlined; tables scroll
horizontally instead of forcing a narrow viewport; and the layout collapses
from navigation / reading / outline columns to one column below 54rem. The
stylesheet honors `prefers-color-scheme: dark` and
`prefers-reduced-motion: reduce`. Native links and headings carry the content
semantics, so no client runtime is needed.

For the authoritative slot and asset rules, see
[`docs/contracts/templating-and-themes.md`](../../../docs/contracts/templating-and-themes.md).
