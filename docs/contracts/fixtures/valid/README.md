# Fixture: valid

**Expect:** exit `0`, full IR under `out/`.

## Layout

```text
content/
  index.md                 # trunk
  guides/intro.md          # trunk
  guides/intro-tips.md     # satellite → guides/intro
```

## Expected graph

| id | role | parent | title | status |
|----|------|--------|-------|--------|
| `guides/intro` | trunk | `null` | `Introduction` | `published` |
| `guides/intro-tips` | satellite | `guides/intro` | `Intro Tips` | `draft` |
| `index` | trunk | `null` | `Home` | `published` |

## Checks

- `schemaVersion` is `"0.1.0"` on `manifest.json`, `graph.json`, and `build-report.json`
- Pages/nodes sorted by `id` as in the table order above
- `graph.json` has `frozen: true`, one `parent` edge, and `nav` derived from
  the frozen graph (breadcrumb / children / siblings by node index)
- Nodes carry `bodyOffset` (not full body text)
- `build-report.json` has `ok: true`, `errorCount: 0`, empty diagnostics
- Committed shapes: [`expected/`](expected/) (paths match the release-gate run)

Goldens assume:

- `contentRoot` = `docs/contracts/fixtures/valid/content`
- `outDir` (report only) = `.release-gate/ir-valid`
