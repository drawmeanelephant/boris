# hostile-starlight fixture

Adversarial **locale-directory** Starlight-shaped tree for
`boris-migration-lab --mode=starlight`.

Probes mechanical classification — never execute this tree with Node/MDX.

| Hostility | Path / note |
|-----------|-------------|
| Entity collision `.md` + `.mdx` same stem | `clash/intro.md` + `clash/intro.mdx` |
| Index collapse vs bare file | `installation.md` + `installation/index.mdx` |
| Deep multi-hop path | `deep/a/b/c.mdx` |
| Unicode path | `guides/café.mdx` |
| Unsupported FM (nested, draft, source id/parent) | `features/alpha.mdx` |
| MDX import/export/expression/components | several |
| Untrusted instruction fence | `features/alpha.mdx` |
| Underscore partial | `tariffs/_dynamic.mdx` |
| Unresolved routes + missing assets | link/image targets |
| Sidebar ghost link | `astro.config.mjs` |

```bash
zig build run -- --mode=starlight \
  --root=./fixtures/hostile-starlight \
  --out=./.hostile-sl-out \
  --locale=en \
  --max-pages=40
```

MIT-shaped sample only.
