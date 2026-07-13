---
title: RAG export command
parent: guides/intro
---

# RAG export command

Boris can export a **Retrieval-Augmented Generation (RAG) corpus**: a tree of
markdown files with stable paths, frontmatter, and catalogs intended for
upload into chat LLM knowledge bases (Grok, Gemini, NotebookLM-style tools,
and similar).

The export is a first-class CLI path. It does **not** shell out to Python,
Node, or zip packagers — everything is written by the Zig binary.

## When to use it

Use RAG export when you want models to answer questions from:

- **System knowledge** — how Boris works (pipeline, Page model, Apex, memory)
- **Site content** — your authored pages under `content/`, with asides inlined
- **Graph structure** — trunk → satellite edges and entity catalogs

The default content-compiler path writes JSON IR under `.boris/`. RAG export
is a separate path that focuses on LLM-friendly markdown instead.

## How to run it

From the repository root (Zig **0.16+**):

```bash
# Convenience build step (recommended)
zig build rag

# Equivalent: run the binary with --rag
zig build run -- --rag

# Write the corpus somewhere other than rag/
zig build run -- --rag-dir=./uploads/boris-rag

# Extra args after zig build rag also work (build.zig forwards them)
zig build rag -- --rag-dir=./uploads/boris-rag
zig build rag -- --quiet
```

Installed binary form:

```bash
./zig-out/bin/boris --rag
./zig-out/bin/boris --rag-dir=./uploads/boris-rag
./zig-out/bin/boris --input=content --rag
./zig-out/bin/boris --help
```

<Aside kind="tip" id="rag-cli-flags">
`--rag-dir=DIR` always implies RAG-only (same as `--rag`). You do not need both
flags. It does **not** mean “IR plus RAG” or “HTML plus RAG.”
</Aside>

### Flags that matter for RAG

| Flag | Effect |
|------|--------|
| `--rag` | Export RAG corpus only (default directory: `rag/`) |
| `--rag-dir=DIR` | Write corpus under `DIR` (implies RAG-only) |
| `--no-rag` | IR-only path (mutually exclusive with `--rag` / `--rag-dir`) |
| `--input=DIR` | Content root to scan (default: `content`) |
| `--quiet` | Suppress progress lines |
| `-h`, `--help` | Print usage (exit 0; no content scan) |

`--out=` applies only to the JSON IR compiler. Passing an explicit `--out=…`
together with `--rag` or `--rag-dir` is a **usage error** (exit 2) — it is never
silently ignored. Choose the corpus directory with `--rag-dir` instead.

Exit codes: `0` success, `1` content/validation, `2` usage/flags, `3` I/O/system.

## What gets written

Default root: `rag/`

```text
rag/
  INDEX.md              # master retrieval map — start here in a chat
  UPLOAD-GUIDE.md       # how to upload / query (Grok, Gemini, …)
  catalog.jsonl         # one JSON object per document (tooling; not a catalog row)
  catalog_meta.json     # format + schema_version + boris_version (not a catalog row)
  system/               # curated architecture seeds from docs/rag/system/
  content/
    pages/              # site pages, mirrored by entity id
  graph/
    entity-catalog.md   # all page entities + roles
    relations.md        # trunk → satellite edges
```

### Segment categories

| Category | Role |
|----------|------|
| `system` | Compiler and architecture knowledge |
| `content` | Author page body + metadata (asides stay on the page) |
| `graph` | Entity catalog and parent edges |
| `meta` | `INDEX.md`, `UPLOAD-GUIDE.md` |

### Design rules (why paths look this way)

1. **Stable hierarchical paths** — content mirrors entity ids  
   (`guides/intro` → `content/pages/guides/intro.md`)
2. **Self-contained segments** — each file restates entity id, role, parent, source
3. **Machine frontmatter** — `rag_id`, `rag_path`, `category`, `tags`, `related`
4. **Metadata-owned H1** — frontmatter `title` is the sole document H1 (source leading H1 stripped)
5. **Asides stay on the page** — callouts become `:::kind` **export** blocks in Body (not authoring syntax; not separate docs)
6. **Graph docs are explicit** — retrieval does not require scanning every page for edges
7. **Deterministic corpus** — sorted keys, no timestamps/hosts/absolute paths; see `docs/contracts/rag-export.md`

## Successful run (what you should see)

A normal `zig build rag` prints progress and a summary similar to:

```text
Boris RAG export boris/0.1.1
  content: content
  rag dir: rag

Exporting RAG corpus → rag/
  rag system  system/00-overview.md
  …
  rag page    content/pages/index.md
  …
  rag graph   graph/entity-catalog.md
  rag graph   graph/relations.md
RAG export complete.
  system=10  pages=N  graph=2  catalog=M

rag done: system=10 pages=N graph=2 catalog=M
  wrote rag/
```

Exit code **0** means the export finished. Counts scale with how many system
seeds and content pages exist.

With `--quiet`, only failures and minimal logging remain.

## What feeds the corpus

| Input | Output |
|-------|--------|
| `docs/rag/system/*.md` | `rag/system/*.md` (normalized frontmatter) |
| `content/**/*.md` | `rag/content/pages/<entity_id>.md` |
| Page graph (from scan + frontmatter) | `rag/graph/*.md` |
| Full catalog of written files | `rag/catalog.jsonl`, `rag/INDEX.md` |

System seeds are optional: if `docs/rag/system/` is missing, Boris warns and
skips that segment; content and graph export still run.

Content pages are re-read and parsed so asides can be inlined. Entity ids
come from source paths (e.g. `guides/rag-export.md` → `guides/rag-export`).

## Uploading the pack

1. Run `zig build rag` (or `--rag-dir=…` for a dedicated upload folder).
2. Upload the **entire** output directory as a knowledge pack when the product allows folder upload.
3. Prefer pinning or citing `INDEX.md` first so the model has a retrieval map.
4. For scripted uploads, iterate `catalog.jsonl` (one JSON object per line; field order fixed) and read `catalog_meta.json` once for format/version.

Minimum useful subset if you must truncate:

1. `INDEX.md`
2. All of `system/`
3. All of `content/`
4. All of `graph/`

Suggested grounding prompt snippet (also written into `UPLOAD-GUIDE.md`):

```text
You are answering questions using the Boris RAG corpus.
Prefer files under system/ for architecture and implementation questions.
Prefer content/pages/ for site/content questions (asides are inlined).
Use graph/relations.md to find trunk→satellite links.
Cite rag_path values from document frontmatter when you rely on a source.
Boris is a Zig + native Apex project; do not assume Node/React unless asked.
```

## Query patterns that retrieve well

| Intent | Start at |
|--------|----------|
| What is Boris? | `system/00-overview.md` |
| How does the pipeline work? | `system/01-architecture-pipeline.md` |
| Trunk vs satellite | `system/03-trunk-and-satellite.md` + `graph/relations.md` |
| This guide / a site page | `content/pages/<entity_id>.md` |
| A tip or callout | same page segment (`:::kind` in Body) |
| Markdown engine | `system/06-apex-native-engine.md` |
| How RAG export works | `system/09-rag-export.md` + this page |

## Relation to the default compiler

| Path | Command | Output |
|------|---------|--------|
| Content compiler (metadata + graph IR) | `zig build run` / `boris` | `.boris/manifest.json`, `graph.json`, `build-report.json` |
| RAG export | `zig build rag` / `boris --rag` | `rag/` corpus tree |

They share discovery of `content/`, but RAG export is **not** a side effect of
the default IR path today — you run it explicitly when you want a knowledge pack.

<Aside kind="info" id="rag-no-html">
RAG export does not produce `dist/` HTML. It produces markdown for LLM upload.
Use the site compile path when you need static pages.
</Aside>

## Troubleshooting

| Symptom | What to check |
|---------|----------------|
| Empty or missing `system/` | Is `docs/rag/system/` present? |
| Page missing from corpus | Is it a `.md` file under the content root? |
| Satellite not linked in `graph/relations.md` | Does the satellite declare `parent: <trunk-entity-id>`? |
| Wrong output location | Did you pass `--rag-dir=` (or forget it and look only under `rag/`)? |
| Exit code 2 | Usage/flag error (unknown flag, `--rag`/`--no-rag` conflict, empty dirs, `--out` with RAG-only) — run `--help` |
| Exit code 3 | I/O or system failure (permissions, disk, unexpected runtime) |
| Exit code 1 | Content/validation errors (more common on the default IR path than pure RAG) |

## See also

- Generated after each export: `rag/INDEX.md`, `rag/UPLOAD-GUIDE.md`
- Architecture seed: `docs/rag/system/09-rag-export.md` (copied into the corpus as `system/09-rag-export.md`)
- CLI overview seed: `docs/rag/system/08-build-cli-and-layout.md`
