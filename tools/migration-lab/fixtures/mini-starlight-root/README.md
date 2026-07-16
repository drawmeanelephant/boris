# mini-starlight-root fixture

Synthetic, redistributable **root-locale** Starlight-shaped tree for
`boris-migration-lab --mode=starlight`.

Mirrors the default-language layout used by [withastro/starlight](https://github.com/withastro/starlight)
docs (`root: { lang: 'en' }` — English files directly under
`src/content/docs/`, other languages in sibling locale directories):

- content root: `src/content/docs/` (no `en/` directory)
- section dirs `guides/`, `components/`
- sibling `de/` locale tree that must **not** be converted when discovering the
  default locale
- MDX imports + component tags
- root-absolute routes (`/guides/pages`) and relative links
- nested unsupported frontmatter
- public assets under `public/`
- delimited untrusted directive fence (stripped, not followed)
- `astro.config.mjs` sidebar evidence (text-scanned only)

Pair with [`../mini-starlight/`](../mini-starlight/) for the **locale-directory**
shape (`src/content/docs/en/…`).

Not an upstream export and contains no production content. MIT-shaped sample only.
