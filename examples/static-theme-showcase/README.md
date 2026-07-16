# Static theme showcase (optional example)

Self-contained **docs + blog** sample that demonstrates Boris’s existing
theme, layout, asset, navigation, TOC, metadata, and `--layout-rule`
behavior. It is **not** product chrome and is **not** required to build or
ship Boris.

## Why this remains an optional example

| Concern | Stance |
|---------|--------|
| Product code | Unchanged — lives only under `examples/static-theme-showcase/` |
| DaisyUI / Tailwind | **Not** bundled; Boris does not ship them |
| Build-time network | **Forbidden** — all CSS/images are local theme assets |
| Node / Tailwind CLI | **Not used** |
| Default CLI site | Still `content/` + `layouts/main.html` |

Use this tree when you want a polished reference for authoring a theme, not
as a dependency of the compiler.

## DaisyUI decision (provenance)

We evaluated an official pinned DaisyUI static CSS artifact
(`daisyui@5.x` package field `browser` → `daisyui.css`, MIT license).

That file is real and license-clear, but it is **not viable** for this
example’s constraints:

1. **Not a complete offline site stylesheet** without Tailwind utilities or
   the Tailwind browser runtime (CDN path expects a script and network).
2. **Standalone CLI / plugin paths** reintroduce a CSS build step or Node-like
   toolchain — excluded by design.
3. Vendoring a ~1 MB nested component sheet would imply Boris “ships DaisyUI,”
   which this repo deliberately does not claim.

**Therefore this showcase uses a hand-authored stylesheet**
(`theme/assets/css/showcase.css`) inspired by the same clean component feel
(soft surfaces, badges, cards, semantic tokens). It is **not DaisyUI**, is
not a fork of DaisyUI, and must not be labeled as DaisyUI.

License for example HTML/CSS/Markdown authored here: same as the repository
unless noted. SVG mark is original to this example.

## Layout

```text
examples/static-theme-showcase/
  README.md                 # this file
  content/                  # Markdown site (Trunk / Satellite)
    index.md
    guides.md + guides/*
    reference.md + reference/*
    blog.md + blog/*
    includes/               # fragment library (not pages)
  theme/
    layouts/
      main.html             # fallback docs layout
      home.html             # id:index
      section.html          # role:trunk
      blog.html             # glob:blog/*
    footer.html
    assets/css/showcase.css
    assets/img/mark.svg
```

## Exact build commands

From the **repository root** (after `zig build`):

### Full HTML build

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

echo $?   # expect 0
```

### Incremental build

```bash
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
  --incremental \
  --quiet
```

Keep outputs under `test-output/…` (gitignored) or another ignored path
**inside** the workspace. Do not commit generated HTML, caches, or `dist/`.

## Expected output

| Artifact | Expectation |
|----------|-------------|
| Exit code | `0` |
| `test-output/static-theme-showcase/index.html` | `data-layout="home"` |
| `…/guides.html`, `…/reference.html`, `…/blog.html` | `data-layout="section"` |
| `…/blog/first-post.html`, `…/blog/second-post.html` | `data-layout="blog"` |
| `…/guides/getting-started.html`, other satellites | `data-layout="main"` |
| `…/assets/css/showcase.css` | present (local copy) |
| `…/assets/img/mark.svg` | present (local copy) |
| Stylesheet / favicon URLs | page-relative only — **no** `http(s)://` |

### Multi-layout selection check

```bash
rg -n 'data-layout=' \
  test-output/static-theme-showcase/index.html \
  test-output/static-theme-showcase/guides.html \
  test-output/static-theme-showcase/blog/first-post.html \
  test-output/static-theme-showcase/guides/getting-started.html
```

### Offline / no CDN check

```bash
# Should print nothing (no network resource URLs in HTML)
rg -n 'https?://' test-output/static-theme-showcase --glob '*.html' || true
```

### Byte-stable repeated output

```bash
OUT=test-output/static-theme-showcase
rm -rf "$OUT" "$OUT".boris-stage

run() {
  ./zig-out/bin/boris \
    --input examples/static-theme-showcase/content \
    --theme examples/static-theme-showcase/theme \
    --layout-rule default id:index \
      examples/static-theme-showcase/theme/layouts/home.html \
    --layout-rule default 'glob:blog/*' \
      examples/static-theme-showcase/theme/layouts/blog.html \
    --layout-rule default role:trunk \
      examples/static-theme-showcase/theme/layouts/section.html \
    --html-dir "$OUT" \
    --quiet
}

run
find "$OUT" -type f ! -path '*/.boris-cache/*' -print0 | sort -z | xargs -0 shasum -a 256 > /tmp/showcase-a.sha
run
find "$OUT" -type f ! -path '*/.boris-cache/*' -print0 | sort -z | xargs -0 shasum -a 256 > /tmp/showcase-b.sha
diff -u /tmp/showcase-a.sha /tmp/showcase-b.sha   # empty diff

# Incremental vs full: rebuild with --incremental should not change page bytes
./zig-out/bin/boris \
  --input examples/static-theme-showcase/content \
  --theme examples/static-theme-showcase/theme \
  --layout-rule default id:index \
    examples/static-theme-showcase/theme/layouts/home.html \
  --layout-rule default 'glob:blog/*' \
    examples/static-theme-showcase/theme/layouts/blog.html \
  --layout-rule default role:trunk \
    examples/static-theme-showcase/theme/layouts/section.html \
  --html-dir "$OUT" \
  --incremental \
  --quiet
find "$OUT" -type f ! -path '*/.boris-cache/*' -print0 | sort -z | xargs -0 shasum -a 256 > /tmp/showcase-c.sha
diff -u /tmp/showcase-a.sha /tmp/showcase-c.sha   # empty diff
```

## Theme markers (closed vocabulary)

Layouts use only Boris markers:

- `{{content}}`, `{{title}}`, `{{nav}}`, `{{breadcrumb}}`, `{{toc}}`
- `{{metadata}}`, `{{footer}}`
- `{{asset-url assets/…}}`

No layout frontmatter key; no live CDN; no JS runtime for styling.

## Related product docs

- [`docs/contracts/templating-and-themes.md`](../../docs/contracts/templating-and-themes.md) — normative theme slots / rules
- [`docs/contracts/html-output.md`](../../docs/contracts/html-output.md) — nav, breadcrumb, TOC shapes
- Acceptance fixtures (smaller): `docs/contracts/fixtures/theme-site/`,
  `docs/contracts/fixtures/layout-rules/`
