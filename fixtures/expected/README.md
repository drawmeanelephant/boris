# Expected IR / RAG samples

Golden / sample artifacts from the product pipelines.

| Path | Source content | Notes |
|------|----------------|-------|
| `valid/` | `fixtures/content/valid` | Full three-file IR set from a successful build |
| `rag/` | `fixtures/content/valid` + `docs/rag/system` | Full RAG corpus tree (m7) |

Regenerate:

```bash
zig build
./zig-out/bin/boris --input fixtures/content/valid --out fixtures/expected/valid --quiet
./zig-out/bin/boris --input fixtures/content/valid --rag-dir fixtures/expected/rag --quiet
```

Contract fixture IR goldens also live at
`docs/contracts/fixtures/valid/expected/`.

These files are **illustrative** and test-supported; normative schemas live in
`docs/contracts/ir-schema.md` and `docs/contracts/rag-export.md`.
