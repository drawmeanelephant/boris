# hostile-theme-astro fixture

Synthetic **hostile** Astro/Starlight-shaped theme for migration-lab
`--mode=theme-archaeology`. Exercises inventory edges without running any
source-site code.

| Case | Where |
|------|--------|
| Runtime scripts / islands | `src/layouts/RuntimeLayout.astro` (`client:load`, inline script) |
| Remote analytics | layout + `public/scripts/tracker.js` reference |
| Remote CSS | `public/css/remote-ref.css` `@import url(https://…)` |
| Env runtime | `src/scripts/env-use.js` (`import.meta.env`) |
| Duplicate assets | identical bytes at `public/images/dup.png` and `public/assets/dup.png` |
| Unsupported components | `src/components/ReactIsland.tsx`, `CustomWidget.astro` |
| Unsupported MDX tags | `src/content/docs/widgets.mdx` (`Tabs`, `CardGrid`) |
| Path traversal | CSS `url(../../secret)`, markdown `](../../../etc/passwd)` |
| Embedded directives | HTML comment + ` ```agent ` fence (must be inventoried, never followed) |

Source tree is **read-only**. No network. No JS/MDX execution.
