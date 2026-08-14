# Bulma classic theme study

A Boris-native, zero-dependency theme study inspired by Bulma’s CSS-only,
mobile-first component vocabulary. The classes are hand-authored for this
example; no Bulma package, CDN, JavaScript, or build step is required.

## What it demonstrates

- Familiar `container`, `columns`, `column`, `box`, `menu`, `tag`, and `hero` shapes
- Three layout variants selected by Boris build rules
- Graph navigation, breadcrumbs, TOC, metadata, direct children, footer, and assets
- Responsive columns, high-visibility focus, dark mode, reduced motion, and print

## Build

```bash
./zig-out/bin/boris \
  --input examples/framework-themes/bulma-classic/content \
  --theme examples/framework-themes/bulma-classic/theme \
  --layout-rule default id:index \
    examples/framework-themes/bulma-classic/theme/layouts/home.html \
  --layout-rule default role:trunk \
    examples/framework-themes/bulma-classic/theme/layouts/section.html \
  --html-dir test-output/bulma-classic \
  --quiet
```

Expected: home, section, and fallback layouts are selected; copied CSS and
page-local SVGs are relative and the output contains no network resources.
Generated HTML belongs under ignored `test-output/`, never in the PR.

This is an inspiration study rather than an official Bulma distribution.
Compiler or renderer defects should be reported upstream with the smallest
fixture; do not add runtime dependencies to the example.
