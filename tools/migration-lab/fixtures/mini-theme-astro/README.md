# mini-theme-astro fixture

Synthetic Astro/Starlight-shaped **theme** tree for migration-lab
`--mode=theme-archaeology` tests. Not a runnable Astro app (no `node_modules`).

| Signal | Where |
|--------|--------|
| Layouts | `src/layouts/BaseLayout.astro` |
| Components | `src/components/Callout.astro`, `Card.astro` |
| CSS + local import | `src/styles/global.css`, `public/css/tokens.css` |
| Font | `public/fonts/site.woff2` |
| Images | `public/images/logo.svg`, `src/assets/hero.png` |
| Sidebar config | `astro.config.mjs` (text-scan only) |
| License | `LICENSE` + `package.json` license field |
| MDX tags | `src/content/docs/index.mdx` (`Aside`, `Card`) |

Source tree is **read-only** for the lab.
