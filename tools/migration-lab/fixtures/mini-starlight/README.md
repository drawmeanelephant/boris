# mini-starlight fixture

Synthetic, redistributable **locale-directory** Starlight-shaped tree for
`boris-migration-lab --mode=starlight`.

Mirrors sites that keep the default language under `src/content/docs/en/`:

- `src/content/docs/en/` content root (locale_dir shape)
- section dirs `features/`, `installation/`
- MDX imports + component tags
- route-style (`/en/…`) and relative links
- nested `sidebar:` frontmatter (unsupported)
- public assets under `public/`
- a delimited untrusted directive fence (stripped, not followed)
- `astro.config.mjs` sidebar evidence (text-scanned only)
- underscore partial under `tariffs/` (excluded from candidates)

Pair with [`../mini-starlight-root/`](../mini-starlight-root/) for the
**root-locale** shape (default language directly under `docs/`).

Not an upstream export and contains no production content. MIT-shaped sample only.
