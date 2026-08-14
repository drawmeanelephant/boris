# Primer engineering theme study

A Boris-native visual study inspired by GitHub Primer: neutral canvas colors,
token-like spacing, compact labels, readable code, and dense but calm technical
documentation. It is not a Primer package or official GitHub implementation.

## What it demonstrates

- Engineering-documentation chrome with labels, boxes, status metadata, and code
- Home, section, and fallback layouts selected by Boris configuration
- Graph navigation, breadcrumbs, TOC, children, metadata, footer, and local assets
- Responsive layout, visible focus, reduced motion, dark mode, and print output
- Local CSS only: no npm, CDN, JavaScript, or remote fonts

## Build

```bash
./zig-out/bin/boris \
  --input examples/framework-themes/primer-engineering/content \
  --theme examples/framework-themes/primer-engineering/theme \
  --layout-rule default id:index \
    examples/framework-themes/primer-engineering/theme/layouts/home.html \
  --layout-rule default role:trunk \
    examples/framework-themes/primer-engineering/theme/layouts/section.html \
  --html-dir test-output/primer-engineering \
  --quiet
```

This is an inspiration study, not a claim of official Primer conformance.
Generated output belongs under ignored `test-output/`; preserve any compiler
or renderer defect as a reproducible upstream issue.
