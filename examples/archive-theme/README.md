# Archive theme example

A small, offline-first pattern for a long-lived visual archive: one landing
Trunk and a deliberately ordered set of child entries. It is hand-authored
HTML and CSS only—no Node, build step, JavaScript, framework, or remote asset.

## Build

From the repository root, after `zig build`:

```bash
./zig-out/bin/boris \
  --input examples/archive-theme/content \
  --theme examples/archive-theme/theme \
  --layout-rule default id:archive \
    examples/archive-theme/theme/layouts/archive.html \
  --html-dir test-output/archive-theme \
  --quiet
```

The exact `id:archive` rule gives the landing page its archive treatment;
children use the theme's `layouts/main.html` fallback. `{{children}}` emits
the direct children in canonical entity-id order, so the `010`, `040`, and
`120` entry ids make the intended order visible without adding an archive
sorting feature.

Archive layouts intentionally omit `{{nav}}`. A full-site tree becomes noisy
as an import grows; this landing page needs a focused, chronological index of
its own entries instead. `{{children}}` keeps that index graph-backed,
page-relative, and deterministic while the entry layout retains a compact
breadcrumb back to the archive.

## Expected output

- `test-output/archive-theme/archive.html` has `data-layout="archive"` and
  local links to `archive/010-first-roll.html`, `040-night-bus.html`, and
  `120-last-light.html`, in that order.
- Each child uses `data-layout="entry"` and has a page-relative breadcrumb.
- `test-output/archive-theme/assets/archive.css` is copied locally; generated
  HTML contains no `http://` or `https://` resources.

For a quick check after building:

```bash
rg -n 'data-layout=|010-first-roll|040-night-bus|120-last-light' \
  test-output/archive-theme/archive.html
rg -n 'https?://' test-output/archive-theme --glob '*.html' || true
```

This is a future pattern for a larger Instagram or personal-photo import, not
a migration tool or new Boris product behavior. Generated output belongs under
an ignored `test-output/` directory and is not committed.
