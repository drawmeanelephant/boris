# boris-source-rag

Standalone **source-code RAG packer** for LLM notebooks and chat uploads.

This tool is **not** the Boris content compiler and **not** product `boris-rag`
(site pages + architecture seeds under `rag/`). It walks selected project trees
and emits a deterministic markdown corpus you can dump into Grok, Gemini,
NotebookLM, or similar.

| | |
|--|--|
| Source | `tools/source-rag/main.zig` |
| Binary | `zig-out/bin/boris-source-rag` |
| Build step | `zig build source-rag` |
| Default output | `source-rag/` (gitignored) |
| Format id | `boris-source-rag` |
| Schema | `1` (`catalog_meta.json`) |

---

## Quick start

From the **repo root** (Zig **0.16+**):

```bash
zig build source-rag
```

Then upload the whole `source-rag/` directory (or zip it first).

```bash
# Custom output directory
zig build source-rag -- --out=./uploads/source-rag

# Avoid the optional combined bundles and their intentional duplicate bytes
zig build source-rag -- --no-bundles

# After install
zig-out/bin/boris-source-rag --help
zig-out/bin/boris-source-rag --out=./source-rag --quiet
```

### Flags

| Flag | Default | Meaning |
|------|---------|---------|
| `-h`, `--help` | | Print usage; exit 0 |
| `-q`, `--quiet` | off | Suppress progress lines |
| `--out=DIR` | `source-rag` | Corpus root |
| `--root=DIR` | `.` | Project root to scan |
| `--max-bytes=N` | `524288` | Skip files larger than N bytes |
| `--no-bundles` | off | Omit the four combined convenience bundles |

Exit codes: **0** success, **2** usage, **3** I/O error.

---

## Output tree

```text
source-rag/
  INDEX.md              # retrieval map — start here in a chat
  UPLOAD-GUIDE.md       # how to upload / query
  boris-source-1.md     # first sorted-path half of non-docs/content files (default)
  boris-source-2.md     # second sorted-path half of non-docs/content files (default)
  boris-docs.md         # all packed docs/** files (default)
  boris-content.md      # all packed content/** files (default)
  catalog.jsonl         # one JSON object per document
  catalog_meta.json     # format + schema_version + tool_version
  files/**              # one markdown document per source path
```

Each source document looks like:

```markdown
---
rag_id: source/src/main.zig
rag_path: files/src/main.zig.md
source_path: src/main.zig
category: source
lang: zig
bytes: 4610
---

# `src/main.zig`

```zig
// file body…
```
```

- Non-`.md` sources → `files/<path>.md`
- Already-`.md` sources → `files/<path>` (no double `.md.md`)
- Fence length grows if the body contains backticks (safe nesting)

### catalog_meta.json

```json
{"format":"boris-source-rag","schema_version":1,"tool_version":"0.1.0"}
```

### catalog.jsonl (field order)

```text
rag_id, rag_path, category, title, source_path, lang, bytes
```

Rows are sorted by `rag_path`. Machine files (`catalog.jsonl`,
`catalog_meta.json`) are **not** catalog rows; meta docs `INDEX.md` and
`UPLOAD-GUIDE.md` **are** rows (`category: meta`).

### Combined upload bundles

By default, the four `boris-*.md` files are additive convenience bundles for
LLM uploads. They intentionally duplicate the per-file `files/**` corpus; the
per-file documents and catalog remain unchanged. Pass `--no-bundles` when
duplicate bytes are undesirable: it still emits `files/**`, `INDEX.md`,
`UPLOAD-GUIDE.md`, `catalog.jsonl`, and `catalog_meta.json`, while omitting all
four combined files. `boris-docs.md`
contains all packed `docs/**` files, and `boris-content.md` contains all packed
`content/**` files. The source corpus is split into `boris-source-1.md` and
`boris-source-2.md` at a whole-document boundary near half of the packed body
bytes in sorted source-path order. This keeps output deterministic and avoids
splitting or reordering a source file, though a large indivisible file may make
the byte sizes differ. Empty groups are still emitted with valid bundle metadata.

---

## What gets packed

### Directories (when present under `--root`)

`src`, `docs`, `content`, `layouts`, `scripts`, `tools`, `test`, `SUPPORT`

### Root files (when present)

`AGENTS.md`, `README.md`, `CHANGELOG.md`, `LICENSE`, `build.zig`, `build.zig.zon`

### Included extensions

`.zig`, `.md`, `.c`, `.h`, `.html`, `.htm`, `.json`, `.jsonl`, `.sh`, `.zon`,
`.txt`, `.yml`, `.yaml`, `.toml`, `.css`, `.svg`, plus extensionless `LICENSE` /
`NOTICE` / `COPYING`.

### Always skipped

| Kind | Examples |
|------|----------|
| Cache / VCS | `.git`, `.zig-cache`, `zig-cache` |
| Build / temp | `zig-out`, `dist`, `test-output`, `.boris`, `.release-gate` |
| Product RAG dumps (top-level only) | `rag/`, `rag1/`, `rag2/` |
| This tool’s default out (top-level) | `source-rag/` |
| Vendored dependencies (top-level only) | `vendor/` |
| Nested product-ish names kept | `docs/rag/**`, `tools/source-rag/**` |
| Junk / binary | `.DS_Store`, files with NUL in the first 8KiB |
| Oversized | larger than `--max-bytes` |

Determinism: no timestamps, host paths, or random ids in corpus files. Paths
are repo-relative. Catalog order is byte-wise `rag_path`.

Regeneration first writes the complete next corpus to a bounded sibling staging
directory. Only after that succeeds does it replace the generated `files/`
subtree and root corpus files, so a generation I/O failure leaves the previous
successful corpus intact. Documents excluded by a newer exporter therefore
cannot remain in the pack after a successful publish. It never removes the
selected output directory or unrelated files beside the generated artifacts.

---

## Product RAG vs source RAG

| | Product `boris-rag` (planned / leftover design) | **This tool** |
|--|--------------------------------------------------|---------------|
| Goal | Site content + architecture narrative for “what is Boris?” | Full source dump for coding LLMs |
| CLI | Future `boris --rag` / `zig build rag` | `zig build source-rag` / `boris-source-rag` |
| Default out | `rag/` | `source-rag/` |
| Includes `src/**/*.zig`? | No | **Yes** |
| Graph / frontmatter validation? | Yes (content graph) | No (plain file walk) |
| Wired into milestone-1 `boris`? | No | No (separate binary) |

If a notebook says “you didn’t pack the source,” use **this** tool and upload
`source-rag/`, not the product `rag/` tree.

---

## LLM upload tips

1. Upload the **entire** `source-rag/` folder (or zip).
2. Pin or open `INDEX.md` as the path map.
3. Prefer `files/src/**` for implementation questions.
4. Prefer `files/docs/contracts/**` for IR / machine contracts.
5. Cite `source_path` from document frontmatter when answering.

Suggested system prompt snippet:

```
You are answering questions about this repository using the source RAG corpus.
Prefer files under files/src/ for implementation details.
Prefer files/docs/contracts/ for normative IR and machine contracts.
Cite source_path from document frontmatter when you rely on a file.
Do not invent APIs that are not present in the corpus.
```

---

## Tests

```bash
zig build test   # includes tools/source-rag unit + mini export fixture
```

---

## Relationship to Boris product rules

- Implemented in **Zig only** (no Node/Python packager).
- Lives under `tools/` so it cannot be mistaken for the content compiler pipeline.
- Does not change product IR, frontmatter, or graph contracts.
