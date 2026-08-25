# Golden fixture: complete-corpus RAG export

Regenerate with:

```bash
boris --rag --complete --input fixtures/content/valid --rag-dir fixtures/expected/rag
```

This directory pins the **complete-corpus** RAG export (`--rag --complete`):

- `system/**` — Boris system seeds (documented, not for upload in normal site work)
- `content/pages/**` — complete, verbatim authoring documents (H1s and `<Aside>`/`<Details>` syntax preserved)
- `graph/**` — entity catalog and relation reports
- `INDEX.md`, `UPLOAD-GUIDE.md`, `catalog.jsonl`, `catalog_meta.json` — corpus envelope

The **default** `--rag` export (working-context packs) is intentionally different:
a small set of `working-N.md` packs plus a `manifest.json` sidecar. See
`docs/contracts/rag-export.md`.

Determinism: regenerating must be byte-identical. The release gate compares
`catalog_meta.json` schema version and the complete-corpus shape.
