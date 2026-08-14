# Open Props laboratory theme study

A Boris-native token laboratory inspired by Open Props: fluid sizes, layered
surfaces, semantic color roles, and a responsive shell built from custom
properties. Open Props is a token toolkit rather than a component framework;
this example explores that distinction with local CSS and no dependency.

## What it demonstrates

- A token-first theme with fluid type, spacing, radii, shadows, and color roles
- Home, section, and fallback layouts using the same token vocabulary
- Graph navigation, breadcrumbs, TOC, metadata, children, footer, and assets
- Dark mode, reduced motion, high-visibility focus, and print behavior
- Fully offline static output with no npm, CDN, JavaScript, or remote fonts

## Build

```bash
./zig-out/bin/boris \
  --input examples/framework-themes/open-props-laboratory/content \
  --theme examples/framework-themes/open-props-laboratory/theme \
  --layout-rule default id:index \
    examples/framework-themes/open-props-laboratory/theme/layouts/home.html \
  --layout-rule default role:trunk \
    examples/framework-themes/open-props-laboratory/theme/layouts/section.html \
  --html-dir test-output/open-props-laboratory \
  --quiet
```

This is a token-inspired study rather than a vendored Open Props build. Keep
generated output ignored and report Boris/Oliver surprises with a minimal
fixture instead of adding an alternate build system.
