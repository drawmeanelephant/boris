# Friendly static docs theme

This is a compact, self-contained documentation-theme pattern with a friendly,
component-like information hierarchy. It is inspired by the approach people
enjoy in DaisyUI—clear cards, soft color, and calm navigation—but is entirely
hand-authored static HTML and CSS.

It is an optional example, not a Boris dependency, product default, or
replacement for the repository's normal `content/` and `layouts/` paths.

## Boundaries

- No DaisyUI, Tailwind, Node, package manager, JavaScript, remote CDN, or
  copied framework code.
- `theme/assets/css/docs.css` is local CSS copied by Boris through
  `{{asset-url …}}`.
- The layout uses existing Boris slots only: navigation, breadcrumb, metadata,
  TOC, direct children, content, and footer.
- The sample content uses the existing Trunk / Satellite graph and `<Aside>`
  tokens. It creates no new authoring semantics.

## Tree

```text
examples/daisy-static-theme/
  content/
    index.md                 # Trunk with direct children
    foundations.md           # Trunk with a Satellite
    foundations/contrast.md  # Satellite
    patterns.md              # Satellite of index
  theme/
    layouts/main.html        # closed Boris template slots
    assets/css/docs.css      # local, hand-authored stylesheet
    footer.html
```

## Exact invocation

Run from the repository root after building Boris:

```bash
zig build

./zig-out/bin/boris \
  --input examples/daisy-static-theme/content \
  --theme examples/daisy-static-theme/theme \
  --html-dir test-output/daisy-static-theme \
  --quiet
```

Open `test-output/daisy-static-theme/index.html` in a browser or serve that
directory with any static-file server. The output is self-contained: it uses
only page-relative local CSS and no runtime requests.

## What to look for

| Boris feature | Example location |
|---|---|
| Full graph nav + current page | left rail, `{{nav}}` |
| Parent trail | top bar, `{{breadcrumb}}` |
| Per-page outline | right rail, `{{toc}}` |
| Direct children | section card, `{{children}}` |
| Status/tags | article header, `{{metadata}}` |
| Tables, code, and Aside | sample Markdown pages |
| Accessible focus and responsive reading | `theme/assets/css/docs.css` |

The CSS honors a dark system preference, provides high-contrast focus rings,
keeps links visibly distinct, and collapses from a three-column reading layout
to one column on smaller screens.

## Determinism check

Run the same command twice, then compare file hashes (excluding the build
cache):

```bash
OUT=test-output/daisy-static-theme

./zig-out/bin/boris --input examples/daisy-static-theme/content --theme examples/daisy-static-theme/theme --html-dir "$OUT" --quiet
find "$OUT" -type f ! -path '*/.boris-cache/*' -print0 | sort -z | xargs -0 shasum -a 256 > /tmp/daisy-theme-a.sha

./zig-out/bin/boris --input examples/daisy-static-theme/content --theme examples/daisy-static-theme/theme --html-dir "$OUT" --quiet
find "$OUT" -type f ! -path '*/.boris-cache/*' -print0 | sort -z | xargs -0 shasum -a 256 > /tmp/daisy-theme-b.sha

diff -u /tmp/daisy-theme-a.sha /tmp/daisy-theme-b.sha
```

An empty diff confirms byte-stable generated files. Keep output under the
ignored `test-output/` directory; do not commit generated HTML or caches.

For the authoritative slot and asset rules, see
[`docs/contracts/templating-and-themes.md`](../../docs/contracts/templating-and-themes.md).
