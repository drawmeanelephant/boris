# Expected RAG artifacts (milestone 7)

Golden samples produced by:

```bash
zig build run -- --input fixtures/content/valid --rag-dir fixtures/expected/rag
```

## What is here

| Path | Role |
|------|------|
| `catalog_meta.json` | Fixed machine meta (`format`, `schema_version`, `boris_version`) |
| `catalog.jsonl` | One JSON object per retrieval document; field order fixed |
| `INDEX.md` / `UPLOAD-GUIDE.md` | Meta retrieval docs |
| `content/pages/**` | Path-mirrored page segments (metadata-owned H1) |
| `graph/**` | Entity catalog + relations |
| `system/**` | Copy of seeds from `docs/rag/system/` at generation time |

## Stability notes

- Primary determinism gate is the dual-export byte-compare test in `src/rag.zig`
  (two distinct dirs, full tree `diff`).
- Regenerating this tree also re-copies `docs/rag/system/`. Narrative seed edits
  change golden system files and INDEX/catalog rows that list them.
- Paths inside artifacts are relative with `/` separators only.
- No timestamps, hostnames, or absolute paths in corpus files.

## Contract

See [`docs/contracts/rag-export.md`](../../../docs/contracts/rag-export.md).
