# Framework-inspired Boris themes

These are first-class **example themes**, not product dependencies. Each is a
small, Boris-native visual translation of a design language that authors may
already know. The CSS is local and hand-authored; no package manager, CDN,
JavaScript runtime, or alternative static-site generator is required.

## Catalog

| Theme | Design question |
|---|---|
| `pico-semantic` | Can semantic HTML and a light class footprint carry the whole shell? |
| `bulma-classic` | How does Boris compose with familiar CSS-only component classes? |
| `govuk-service` | Can a docs graph read like a disciplined public service? |
| `primer-engineering` | Can dense engineering documentation stay calm and scannable? |
| `uswds-public` | How should tokens, alerts, banners, and civic content work together? |
| `open-props-laboratory` | What happens when fluid custom properties are the primary design system? |

## Shared fixture

Every theme uses the same small reference-shaped Markdown corpus so visual
comparisons are meaningful. It contains a home Trunk, Guides and Reference
Trunks, Satellite pages, tables, code, callouts, Details, and page-local SVG
assets. Each theme changes the layout and CSS, not the compiler contract.

## Shared build shape

From the repository root, replace `<theme>` with one catalog name:

```bash
./zig-out/bin/boris \
  --input examples/framework-themes/<theme>/content \
  --theme examples/framework-themes/<theme>/theme \
  --layout-rule default id:index \
    examples/framework-themes/<theme>/theme/layouts/home.html \
  --layout-rule default role:trunk \
    examples/framework-themes/<theme>/theme/layouts/section.html \
  --html-dir test-output/<theme> \
  --quiet
```

Check the selected `data-layout` markers, generated graph slots, copied theme
assets, page-local assets, keyboard focus, narrow-width stacking, and the
absence of network URLs. Keep output under ignored `test-output/` and do not
commit generated HTML or caches.

The shared `published-pages.txt` file is suitable for the standalone search
indexer when auditing any of these six output directories; it keeps compiler
proof artifacts out of the live-page list.

## Boundary

The names communicate design provenance, not official framework integration or
conformance. If a future example vendors upstream CSS, it must record the
exact version and license locally. A Boris example must not introduce that
framework as a dependency of the compiler.
