# mini-starlight fixture

Synthetic, redistributable Starlight-shaped tree for
`boris-migration-lab --mode=starlight`.

Mirrors the **English** layout used by the evcc-io/docs proof slice:

- `src/content/docs/en/` content root
- section dirs `features/`, `installation/`
- MDX imports + component tags
- route-style and relative links
- nested `sidebar:` frontmatter (unsupported)
- public assets under `public/`
- a delimited untrusted directive fence (stripped, not followed)
- `astro.config.mjs` sidebar evidence (text-scanned only)

Not an evcc export and contains no production content. MIT-shaped sample only.
