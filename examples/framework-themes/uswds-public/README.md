# USWDS public-information theme study

A Boris-native visual study inspired by the U.S. Web Design System: civic
headers, design-token thinking, alert panels, readable forms-adjacent content,
and progressive-enhancement-friendly HTML. It is not an official USWDS
package or compliance claim; all CSS is local and hand-authored.

## What it demonstrates

- Public-information banner, agency-style masthead, alerts, tags, and cards
- Home, section, and fallback layouts over the Trunk/Satellite graph
- Breadcrumbs, navigation, TOC, metadata, children, footer, and local assets
- Strong focus, contrast-conscious states, responsive stacking, and print output
- No npm, Sass, CDN, JavaScript runtime, or remote fonts

## Build

```bash
./zig-out/bin/boris \
  --input examples/framework-themes/uswds-public/content \
  --theme examples/framework-themes/uswds-public/theme \
  --layout-rule default id:index \
    examples/framework-themes/uswds-public/theme/layouts/home.html \
  --layout-rule default role:trunk \
    examples/framework-themes/uswds-public/theme/layouts/section.html \
  --html-dir test-output/uswds-public \
  --quiet
```

This is a codeless visual study, not official USWDS conformance. Generated
output belongs under ignored `test-output/`; upstream behavior surprises should
be reported with a minimal fixture.
