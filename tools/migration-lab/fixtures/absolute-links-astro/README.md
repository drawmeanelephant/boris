# absolute-links-astro fixture

Synthetic Astro tree for site-root absolute link classification:

| Target | Expected class |
|--------|----------------|
| `/` | valid route (`src/pages/index.astro`) |
| `/about` | valid route (`src/pages/about.astro`) |
| `/no-such-page` | **broken internal link** (not missing asset) |
| `/images/hero.png` (`src` / image) | valid public asset |
| `/images/missing.png` (`src` / image) | **missing asset** |

Reproduces the P1 bug where absolute hrefs were blindly mapped to `public/`.
