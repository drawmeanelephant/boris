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

# Bundles-only upload pack (no per-file files/** tree)
zig build source-rag -- --bundles-only

# Partition combined bundles at a 256 KiB body-byte target (whole files only)
zig build source-rag -- --split-size=262144

# Export a bounded logical profile (all remains the default)
zig build source-rag -- --profile=core --no-bundles

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
| `--split-size=N` | `524288` | Target body bytes per combined bundle part |
| `--no-bundles` | off | Omit combined convenience bundles and parts |
| `--bundles-only` | off | Emit combined bundles + sidecars only; omit `files/**` |
| `--profile=NAME` | `all` | Select `all`, `core`, `docs`, or `tools` input scope |

`--no-bundles` and `--bundles-only` are mutually exclusive.

Exit codes: **0** success, **2** usage, **3** I/O error.

---

## Output tree

```text
source-rag/
  INDEX.md              # retrieval map — start here in a chat
  UPLOAD-GUIDE.md       # how to upload / query
  boris-source-N.md     # ordered whole-file parts for non-docs/content files
  boris-docs[-N].md     # one or more ordered whole-file docs parts
  boris-content[-N].md  # one or more ordered whole-file content parts
  catalog.jsonl         # one JSON object per document
  catalog_meta.json     # format + schema_version + tool_version + profile + split target
  profile_manifest.json  # selected profile, counts, and sorted packed paths
  part_manifest.json     # profile, ordered parts, source paths, and byte counts
  upload_manifest.json   # --bundles-only only: upload order, sizes, chars/4 token estimates
  files/**              # one markdown document per source path (omitted with --bundles-only)
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
{"format":"boris-source-rag","schema_version":1,"tool_version":"0.1.0","profile":"all","split_size":524288}
```

### catalog.jsonl (field order)

```text
rag_id, rag_path, category, title, source_path, lang, bytes
```

Rows are sorted by `rag_path`. Machine files (`catalog.jsonl`,
`catalog_meta.json`, `profile_manifest.json`, `part_manifest.json`) are **not** catalog rows; meta docs `INDEX.md` and
`UPLOAD-GUIDE.md` **are** rows (`category: meta`).

### Combined upload bundles

By default, the `boris-*.md` files are additive convenience bundles for LLM
uploads. They intentionally duplicate the per-file `files/**` corpus; the
per-file documents and catalog remain unchanged. `--split-size=N` sets a target
for combined bundle body bytes. Files are packed contiguously in sorted
source-path order and are never split. If one accepted source file is larger
than `N`, it is emitted whole in its own part and that part may exceed `N`.
Empty groups still emit a valid empty part.

`part_manifest.json` is the authoritative part map. It records the selected
profile and split target, then each part’s global order, filename, bundle kind,
per-kind order, body byte count, and ordered source paths with their byte
counts. Use it to upload parts in order or to verify that no source was
duplicated or omitted. `--no-bundles` omits all combined part files and emits
the same manifest with `"bundles":false` and an empty `parts` array; the
per-file corpus and sidecars remain available.

### Bundles-only mode (`--bundles-only`)

Use this when the upload target prefers a small number of large Markdown parts
instead of hundreds of per-file documents:

```bash
zig build source-rag -- --bundles-only --out=./uploads/source-rag
# optional: bound each part
zig build source-rag -- --bundles-only --split-size=262144
# optional: narrower scope
zig build source-rag -- --bundles-only --profile=core
```

Emitted artifacts:

| Artifact | Role |
|----------|------|
| `INDEX.md` | Retrieval map (notes that `files/**` is omitted) |
| `UPLOAD-GUIDE.md` | Upload / system-prompt guidance for the bundles pack |
| `catalog.jsonl` | One JSON object per source (logical `files/...` rag paths) |
| `catalog_meta.json` | Format + schema + profile + split target |
| `profile_manifest.json` | Selected profile, counts, sorted packed paths |
| `part_manifest.json` | Ordered parts, sources, and body byte counts |
| `upload_manifest.json` | Recommended upload order, on-disk sizes, total bytes, chars/4 tokens |
| `boris-source-*.md` / `boris-docs[-*].md` / `boris-content[-*].md` | Combined parts |

Not emitted: the per-file `files/**` tree. Catalog rows still inventory each
packed source with stable `rag_path` values under `files/` so catalogs and
manifests stay aligned; those paths are logical ids, not on-disk documents in
this mode.

### upload_manifest.json (`--bundles-only` only)

Default and `--no-bundles` exports do **not** write this file. Existing
`catalog_meta.json`, `catalog.jsonl`, `profile_manifest.json`, and
`part_manifest.json` schemas are unchanged.

```json
{
  "profile": "all",
  "split_size": 524288,
  "token_estimate_method": "chars/4",
  "total_bytes": 1234567,
  "approx_tokens": 308641,
  "files": [
    {"order": 1, "file": "INDEX.md", "bytes": 1200, "approx_tokens": 300},
    {"order": 2, "file": "UPLOAD-GUIDE.md", "bytes": 1800, "approx_tokens": 450}
  ]
}
```

| Field | Meaning |
|-------|---------|
| `profile` | Selected export profile |
| `split_size` | Configured body-byte target for combined parts |
| `token_estimate_method` | Always `"chars/4"` — documented planning heuristic, not a tokenizer |
| `total_bytes` | Sum of on-disk byte sizes of listed upload files |
| `approx_tokens` | `floor(total_bytes / 4)` |
| `files[].order` | Recommended upload order (1-based) |
| `files[].file` | Generated upload filename |
| `files[].bytes` | On-disk size of that file |
| `files[].approx_tokens` | `floor(bytes / 4)` for that file |

Recommended order: `INDEX.md`, `UPLOAD-GUIDE.md`, machine sidecars
(`part_manifest.json`, `catalog_meta.json`, `profile_manifest.json`,
`catalog.jsonl`), then combined parts in `part_manifest.json` global order.
`upload_manifest.json` itself is a planning sidecar and is **not** listed in
`files` (so totals describe the corpus you actually upload to a model).

A successful `--bundles-only` rerun uses the same staged publication path as a
normal export. Managed artifacts from the previous pack (including a prior
`files/` tree) are replaced; stale per-file documents are removed. A later
default export also removes a prior `upload_manifest.json`. Unrelated siblings
beside the managed corpus are left alone. Two successive successful
`--bundles-only` runs on the same input produce byte-identical managed output.

### Profiles

The default `all` profile preserves the complete historical scan. Use a
profile when an LLM upload should be bounded by purpose:

| Profile | Included roots |
|---------|----------------|
| `core` | root project guidance/build files, `src/`, and `layouts/` |
| `docs` | `docs/` and `content/` |
| `tools` | `scripts/`, `tools/`, `test/`, and `SUPPORT/` |

Every export records the selected profile in `catalog_meta.json` and emits a
deterministic `profile_manifest.json` containing counts and sorted paths for
documents actually packed. Candidates skipped as oversized, binary, or unreadable
are counted in `skipped` and omitted from `paths`. Profile selection changes scope
only; the same path, fence, catalog ordering, staged publication, and vendor/cache
exclusion rules still apply.

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

### Default pack (`files/**` + bundles)

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

### Bundles-only upload workflow

1. Generate with `zig build source-rag -- --bundles-only` (add `--profile` /
   `--split-size` as needed).
2. Open `upload_manifest.json` for recommended order, per-file sizes, total
   upload bytes, and approximate tokens (`chars/4`).
3. Upload the whole output directory, or at minimum the files listed in
   `upload_manifest.json` (plus the planner itself if you want it for later):
   - `INDEX.md`, `UPLOAD-GUIDE.md`
   - `part_manifest.json` (authoritative part/source map)
   - every `boris-source-*.md`, `boris-docs[-*].md`, `boris-content[-*].md`
   - `catalog.jsonl`, `catalog_meta.json`, `profile_manifest.json`
4. Upload in `upload_manifest.json` order when the host limits concurrent
   files; keep whole parts (never hand-split a part mid-document).
5. Prefer `boris-source-N.md` for implementation questions and `boris-docs`
   parts for contracts.
6. Cite `source_path` from each embedded document’s frontmatter.

Suggested system prompt snippet (bundles-only):

```
You are answering questions about this repository using the source RAG corpus.
Prefer boris-source-N.md for implementation details.
Prefer boris-docs parts for normative IR and machine contracts.
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
