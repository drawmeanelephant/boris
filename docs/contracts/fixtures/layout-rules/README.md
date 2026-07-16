# Layout-rules fixture

Acceptance fixture for deterministic page layout selection
(`docs/designs/page-layout-selection-rfc.md`,
`docs/contracts/templating-and-themes.md` §4).

```text
content/                         theme-site graph shape (Trunk/Satellite)
theme/layouts/main.html          fallback
theme/layouts/home.html          id:index
theme/layouts/reference.html     glob:reference/*
theme/layouts/section.html       role:trunk
theme/footer.html
theme/assets/css/docs.css
```

## Success invocation

```bash
boris \
  --input docs/contracts/fixtures/layout-rules/content \
  --theme docs/contracts/fixtures/layout-rules/theme \
  --layout-rule default id:index \
    docs/contracts/fixtures/layout-rules/theme/layouts/home.html \
  --layout-rule default 'glob:reference/*' \
    docs/contracts/fixtures/layout-rules/theme/layouts/reference.html \
  --layout-rule default role:trunk \
    docs/contracts/fixtures/layout-rules/theme/layouts/section.html \
  --html-dir /tmp/layout-rules-out \
  --quiet
```

Expected `data-layout` markers:

| Page | Selector win | Marker |
|------|--------------|--------|
| `index` | exact id | `home` |
| `guides` | role:trunk | `section` |
| `guides/getting-started` | fallback | `main` |
| `reference` | role:trunk | `section` |
| `reference/configuration` | glob | `reference` |

Rule order permutations must produce byte-identical HTML. Full vs
`--incremental` repeated runs must match (cache format
`boris-cache-v2-layout-rules`).

## Failure cases

| Case | Expect |
|------|--------|
| Equal-specificity globs for one page | exit 2, no publish |
| `layout:` frontmatter | exit 1, `EFRONTMATTER` |
| Cross-theme rule layouts | exit 2 `MixedThemeRoots` |
| `--layout-rule` with `--out` / `--rag` | exit 2 |

## Hostile coverage

Adversarial integration (precedence, ambiguity, order independence, fallback
chain, path/mixed-theme failures, multi-target isolation, incremental/full
equivalence, determinism) lives under [`hostile/`](hostile/) and
`src/layout_select_hostile_test.zig` (`zig build test-layout-hostile`).
