# Pico semantic theme study

A Boris-native, zero-dependency theme study inspired by Pico CSS’s semantic
HTML approach. It is not a vendored Pico distribution or an official Pico
adapter: the CSS is local, hand-authored, and shaped around Boris’s closed
layout vocabulary.

## What it demonstrates

- Semantic landmarks with a light class footprint
- `home.html`, `section.html`, and fallback `main.html` layouts
- Graph navigation, breadcrumbs, TOC, metadata, children, footer, and local assets
- Native `<details>`, visible focus, dark mode, reduced motion, and print output
- Offline output with no CDN, JavaScript runtime, or remote font

## Build

From the Boris repository root:

```bash
./zig-out/bin/boris \
  --input examples/framework-themes/pico-semantic/content \
  --theme examples/framework-themes/pico-semantic/theme \
  --layout-rule default id:index \
    examples/framework-themes/pico-semantic/theme/layouts/home.html \
  --layout-rule default role:trunk \
    examples/framework-themes/pico-semantic/theme/layouts/section.html \
  --html-dir test-output/pico-semantic \
  --quiet
```

Expected: `index.html` uses `data-layout="home"`, section landings use
`data-layout="section"`, satellites use `main`, and theme/page-local assets
remain page-relative. Keep generated output under ignored `test-output/`.

This is a visual study, not a product dependency. If the compiler or renderer
behaves unexpectedly, preserve the fixture and report the issue instead of
adding a framework runtime or changing Boris.
