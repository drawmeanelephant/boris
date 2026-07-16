# mini-astro fixture

Synthetic Astro project tree for `boris-migration-lab` archaeology tests.

Intentionally includes:

| Signal | Where |
|--------|--------|
| Content collection pages | `src/content/docs/**`, `src/content/blog/**` |
| Dynamic page routes | `src/pages/docs/[...slug].astro`, `src/pages/blog/[slug].astro` |
| Standalone route | `src/pages/about.astro` |
| Layouts | `src/layouts/*.astro` |
| MDX + JSX component | `src/content/docs/guides/components.mdx` |
| Nested YAML + `parentEntry` + `draft` | `src/content/docs/guides/deep.md` |
| Duplicate slug | blog `post-one.md` + `post-one.mdx` (`shared-slug`) |
| Broken links | `does-not-exist.md`, `ghost.md` |
| Missing assets | `/images/missing-banner.png`, `/images/not-there.png` |
| Present assets | `public/images/hero.png`, `src/assets/logo.svg` |

This fixture is **not** a runnable Astro app in CI (no `node_modules`). It is source-shaped input for the read-only scanner.
