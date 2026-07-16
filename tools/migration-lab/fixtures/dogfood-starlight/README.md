# dogfood-starlight fixture

Synthetic, redistributable **root-locale** Starlight-shaped dogfood tree for
`boris-migration-lab --mode=starlight`.

## Pin / shape

Modeled on the [withastro/starlight](https://github.com/withastro/starlight)
documentation package layout (English at `src/content/docs/`, other languages in
sibling locale directories). **Not** an upstream export — no production text,
no Node install, no package lock.

Documented real-site smoke pin (clone to `/tmp` only, never commit upstream):

```text
https://github.com/withastro/starlight
commit 02fea60ecf5b07449dc6620cb85bd746944b79aa
project root for docs package: <clone>/docs
```

This fixture deliberately expands past a proof-slice mini tree into roughly
**50–70** default-locale pages so selection, link, asset, nav, and boundary
reports exercise serious dogfood cardinality.

## Coverage

| Area | Present |
|------|---------|
| Root-locale English | `src/content/docs/*` |
| Sibling locales skipped | `de/`, `zh-cn/` |
| Nested guides + reference + components | yes |
| Blog-like nested year paths | `blog/2024/…`, `blog/2025/…` |
| Route-style + relative links + fragments | yes |
| Public + content-local assets | `public/`, `guides/assets/`, `features/img/` |
| Frontmatter variants | `sidebar`, `draft`, `template`, `hero`, `date`, `badge`, … |
| MDX imports / components | many pages |
| Sidebar / autogenerate evidence | `astro.config.mjs` (text scan only) |
| Underscore partials | `guides/_partial-shared.mdx` (not selected) |
| Untrusted directive fence | `getting-started.mdx` (stripped, not followed) |
| Attribute `href` links | authoring-content |

## Run

```bash
zig build run -- --mode=starlight \
  --root=./fixtures/dogfood-starlight \
  --out=./.dogfood-sl-out \
  --locale=en \
  --max-pages=80
```

MIT-shaped sample only. Source remains read-only.
