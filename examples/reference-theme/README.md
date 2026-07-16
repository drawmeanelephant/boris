# Boris reference theme (optional example)

A polished, **accessibility-forward** documentation theme that dogfoods the
current Boris HTML theme surface for the v0.5.1 line. It is **not** product
chrome and is **not** required to build or ship Boris.

## Why this example exists

| Concern | Stance |
|---------|--------|
| Product code | Unchanged — lives only under `examples/reference-theme/` |
| Framework CSS | **None** — hand-authored local stylesheet |
| Node / npm / Tailwind / CDN | **Forbidden** |
| JS runtime | **None** (native `<details>` only) |
| Default CLI site | Still `content/` + `layouts/main.html` |

Use this tree when you want a readable, keyboard-friendly reference for
authoring a theme that exercises post-v0.5 capabilities (closed `Details`,
page-local `.assets/`, multi-layout selection, and graph slots).

## Tree

```text
examples/reference-theme/
  README.md
  content/
    index.md + index.assets/rhythm-diagram.svg
    guides.md
    guides/getting-started.md
    guides/components.md + guides/components.assets/component-flow.svg
    reference.md
    reference/slots-and-rules.md
  theme/
    layouts/
      main.html      # fallback docs shell (nav + toc + children)
      home.html      # id:index hero landing
      section.html   # role:trunk children-first landing
    footer.html
    assets/css/reference.css
    assets/img/mark.svg
```

## Exact build commands

From the **repository root** (after `zig build`):

### Full HTML build

```bash
zig build

./zig-out/bin/boris \
  --input examples/reference-theme/content \
  --theme examples/reference-theme/theme \
  --layout-rule default id:index \
    examples/reference-theme/theme/layouts/home.html \
  --layout-rule default role:trunk \
    examples/reference-theme/theme/layouts/section.html \
  --html-dir test-output/reference-theme \
  --quiet

echo $?   # expect 0
```

### Incremental build

```bash
./zig-out/bin/boris \
  --input examples/reference-theme/content \
  --theme examples/reference-theme/theme \
  --layout-rule default id:index \
    examples/reference-theme/theme/layouts/home.html \
  --layout-rule default role:trunk \
    examples/reference-theme/theme/layouts/section.html \
  --html-dir test-output/reference-theme \
  --incremental \
  --quiet
```

Keep outputs under `test-output/…` (gitignored) or another ignored path
**inside** the workspace. Do not commit generated HTML, caches, or `dist/`.

## Expected output

| Artifact | Expectation |
|----------|-------------|
| Exit code | `0` |
| `test-output/reference-theme/index.html` | `data-layout="home"` |
| `…/guides.html`, `…/reference.html` | `data-layout="section"` |
| `…/guides/getting-started.html`, satellites | `data-layout="main"` |
| `…/assets/css/reference.css` | present (theme copy) |
| `…/assets/img/mark.svg` | present (theme copy) |
| `…/index.assets/rhythm-diagram.svg` | page-local asset |
| `…/guides/components.assets/component-flow.svg` | page-local asset |
| Stylesheet / image URLs | page-relative only — **no** `http(s)://` |

### Multi-layout selection check

```bash
rg -n 'data-layout=' \
  test-output/reference-theme/index.html \
  test-output/reference-theme/guides.html \
  test-output/reference-theme/guides/getting-started.html
```

### Dogfood surface check

```bash
rg -n 'admonition--|class="details"|page-children|page-toc|site-nav|index.assets|components.assets' \
  test-output/reference-theme/index.html \
  test-output/reference-theme/guides.html \
  test-output/reference-theme/guides/components.html
```

### Offline / no CDN check

```bash
# Should print nothing (no network resource URLs in HTML)
rg -n 'https?://' test-output/reference-theme --glob '*.html' || true
```

### Byte-stable repeated output

```bash
OUT=test-output/reference-theme
rm -rf "$OUT" "$OUT".boris-stage

run() {
  ./zig-out/bin/boris \
    --input examples/reference-theme/content \
    --theme examples/reference-theme/theme \
    --layout-rule default id:index \
      examples/reference-theme/theme/layouts/home.html \
    --layout-rule default role:trunk \
      examples/reference-theme/theme/layouts/section.html \
    --html-dir "$OUT" \
    --quiet
}

run
find "$OUT" -type f ! -path '*/.boris-cache/*' -print0 | sort -z | xargs -0 shasum -a 256 > /tmp/reference-theme-a.sha
run
find "$OUT" -type f ! -path '*/.boris-cache/*' -print0 | sort -z | xargs -0 shasum -a 256 > /tmp/reference-theme-b.sha
diff -u /tmp/reference-theme-a.sha /tmp/reference-theme-b.sha   # empty diff
```

## Accessibility and reading features

The theme CSS and layouts aim for:

- Semantic landmarks (`banner`, `main`, `contentinfo`, named `nav`/`aside`)
- Skip link to main content
- Visible `:focus-visible` rings (high-contrast amber/orange)
- Sufficient default light/dark contrast via system preference
- `prefers-reduced-motion` (disables smooth scroll and marker animation)
- Keyboard-native `<details>` summaries with focus styles
- Responsive collapse from three columns → one reading column

## Theme markers (closed vocabulary)

Layouts use only Boris markers:

- `{{content}}`, `{{title}}`, `{{nav}}`, `{{breadcrumb}}`, `{{toc}}`
- `{{children}}`, `{{metadata}}`, `{{footer}}`
- `{{asset-url assets/…}}`

No layout frontmatter key; no live CDN; no JS runtime for styling.

## Known theme boundaries

| Boundary | Detail |
|----------|--------|
| Not product chrome | Optional under `examples/`; default site is unchanged |
| No template language | No conditionals, loops, or partial includes beyond `footer.html` |
| No shared media library | Page-local assets are sibling `.assets/` only |
| Brand home link | Brand mark is non-navigating text; use `{{nav}}` / breadcrumb for traversal |
| Empty children | Childless pages emit empty `{{children}}`; section landings with satellites populate the list |
| Multi-root home | Home is a sibling Trunk of Guides/Reference, so it uses `{{nav}}` rather than `{{children}}` |
| Visual QA | Automated gates check structure and offline assets, not pixel screenshots |

## Related product docs

- [`docs/contracts/templating-and-themes.md`](../../docs/contracts/templating-and-themes.md)
- [`docs/contracts/html-output.md`](../../docs/contracts/html-output.md)
- [`docs/contracts/content-local-assets.md`](../../docs/contracts/content-local-assets.md)
- [`docs/contracts/components.md`](../../docs/contracts/components.md)
