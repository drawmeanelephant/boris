# Migration site fixture

Realistic **Contoso** documentation tree for practicing a Markdown-site
migration into Boris. Content + theme only — no product code changes.

Author guide: [`docs/MIGRATION.md`](../../docs/MIGRATION.md).

## Layout

```text
fixtures/migration-site/
  content/                 # Markdown pages + includes/
  theme/
    layouts/main.html      # closed layout slots + asset-url
    footer.html
    assets/css/site.css
    assets/img/mark.svg
  expected/README.md       # what a successful build produces
  README.md                # this file
```

## Page inventory (≈32 pages)

| Section | Role |
|---------|------|
| `index` | Home Trunk |
| `guides` + children | Authoring Trunk / Satellites (includes deep path) |
| `reference` + children | CLI, IDs, graph, mixed-case `HTTP-status` |
| `concepts` + children | Trunk/Satellite vocabulary |
| `ops` + children | Incremental, multi-target, watch/jobs |
| `cookbook` + children | Hugo / MkDocs / Docusaurus + rename checklist |
| `special/CaseDemo`, `special/cafe-notes` | Case + Unicode body demos (Trunks) |
| `includes/*` | Fragments only (not pages) |

## Compile (from repo root)

```bash
zig build

./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --theme fixtures/migration-site/theme \
  --html-dir test-output/migration-dist \
  --quiet

echo $?   # expect 0
ls test-output/migration-dist/index.html
ls test-output/migration-dist/assets/css/site.css
ls test-output/migration-dist/guides/deep/nested/path/note.html
```

Keep outputs under `test-output/…` (gitignored) or another ignored path
**inside** the workspace. Boris rejects workspace-escaping output dirs.
Do not commit `dist/`, `rag/`, `.boris/`, caches, or source-RAG packs.

## IR smoke

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --out test-output/migration-ir \
  --quiet
```

Expect `manifest.json`, `graph.json`, and `build-report.json` under the out dir.
