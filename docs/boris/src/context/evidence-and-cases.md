---
title: "`src/context.zig` evidence and cases"
id: docs/boris/src/context/evidence-and-cases
parent: docs/boris/src/context
status: draft
tags: [boris, zig, source-reference, evidence, context]
---

# `src/context.zig` evidence and cases

## Control flow (`run`)

```text
reject absolute content_root
pipeline.compile(content_root, quiet, input_format)
if !compile.ok → return result (published=false)
open content_dir
selected = exportscope.selectPages(pages, scope)
for each selected page (pipeline order among selected):
  source = read(source_path) into compile arena
  source_hash = SHA-256 hex of full source bytes
  page_doc = renderPageDoc(page, source, hash)   # full source in fence
  page_hash = SHA-256 hex of page_doc bytes
  append PageArtifact
  if split_size:
    body = source[body_offset..]  (InvalidBodyOffset if offset past end)
    chunks = renderContextChunks(page, body, hash, cap)
graph = pipeline.renderGraph(compile)
bundle = renderBundle(artifacts)
parts = renderParts(chunks, split_size)
manifest = renderManifest(...)
write stage: bundle.md, graph.json, manifest.json, pages/*.md, parts/*
publish(stage → outdir)
published = true
```


### Page document shape

YAML-like frontmatter (hand-built, not a YAML parser):

- `boris-context-page` / `version: 1`
- `entity_id`, `source_path`, `source_sha256`, `role`, `title`, `parent`
- optional `part: {number,count,continuation}` when chunked (`single` / `continues` / `continued`)
- `relations:` list of `- kind` / `target` from `semantic_relations`
- body: `# {title}`, then fenced `markdown` source (fence length = max(3, longest backtick run + 1))

Full-page docs fence the **entire file source** (including original frontmatter). Chunk docs fence **body pieces** only, with the same provenance header and shared `source_sha256` of the full source file.

### Bundle document

- Header `boris-context` / version / content_root / ir_schema_version / page_count / relation count
- Short human intro + bullet TOC (`id`, title, source_path)
- Concatenation of each `page_doc` separated by `---`


### Manifest (JSON object, hand-escaped)

Notable fields:

- `format`, `schema_version`, `compiler`, `ir_schema_version`, `content_root`
- `scope` (string or empty), `scope_closure: "parents+semantic-relations"`
- **`graph_scope: "full"`** always (even when pages are scoped)
- `graph_page_count` vs `page_count` / `selected_page_count`
- `graph_relation_count` vs `selected_relation_count` / `relation_count`
- `split_size`, `part_count`, `chunk_count`, `parts[]` with paths/bytes/chunk provenance
- `artifacts`: `bundle.md` + `graph.json` SHA-256, then each `pages/{id}.md` hash

Compiler/IR schema strings:

- Relations present → semantic pipeline ids/versions
- Else → base pipeline ids/versions


### Split path

1. Probe header size with empty body and worst-case part numbers → `body_budget = cap - header_len`.
2. `partitionMarkdown(body, body_budget)` — fails `OversizedBlock` if no safe split.
3. Each piece re-rendered with part metadata; each doc must still be `≤ cap`.
4. `renderParts` packs chunk docs into parts under the same cap (prefix label + docs); single chunk larger than cap → `OversizedBlock`.

## Test suite

### Module tests (`src/context.zig`)

| Test | Purpose | Expected | Contract |
| :-- | :-- | :-- | :-- |
| `context chunks preserve provenance and fenced source boundaries` | Split rendering | Multiple chunks ≤ cap; each has `entity_id`, `source_sha256`, `part`/`count`; fence-safe body split | Split provenance |
| `scoped context explicitly marks its graph as full` | Scope vs graph.json policy | `manifest.json` contains `graph_scope` full and `selected_page_count` 1 | Full graph always published |

Related coverage lives in `exportscope.zig` (selectPages closure, partition fences/OversizedBlock) and CLI conflict tables for `--context` vs other modes. CHANGELOG notes stage cleanup after failed writes/publishes.

## Hostile-case walkthroughs

### Absolute content root

**Injected:** `content_root = "/abs/content"`.
**Boundary:** `run` entry.
**Expected:** `AbsoluteContentRoot`; no compile side effects required.
**Forbidden:** Embedding host-absolute roots into bundle metadata as a supported mode.

### Invalid / traversal scope

**Injected:** `--scope ""`, `"..mascots"`, missing id.
**Boundary:** `exportscope.selectPages`.
**Expected:** `InvalidScope` → CLI content error; no publish.
**Evidence:** exportscope unit tests; main maps error.

### Compile failure mid-tree

**Injected:** broken parent / duplicate id content.
**Boundary:** `pipeline.compile`.
**Expected:** `ContextResult` with `ok=false`, `published=false`; no outdir replace.
**Forbidden:** Emitting bundle from a non-validated graph.

### Oversized fenced block under `--split-size`

**Injected:** fence or paragraph larger than cap with no safe boundary.
**Boundary:** `partitionMarkdown` / `renderContextChunks` / `renderParts`.
**Expected:** `OversizedBlock`; prior successful context dir untouched if publish not reached; stage deleted.
**Forbidden:** Silent mid-fence truncation or shipping a partial stage as final.

### Scoped export must not ship partial graph.json

**Injected:** `--scope page` on multi-page site.
**Boundary:** `renderGraph` uses full `result.compile`; manifest labels `graph_scope: full`.
**Expected:** `pages/` only selected (+ closure); `graph.json` still full site; selected counts differ from graph counts.
**Evidence:** scoped unit test.
**Forbidden:** Filtering graph.json to the projection without renaming the contract (would lie about validation universe).

### Failed publish restore

**Injected:** rename race / permission fail after stage complete.
**Boundary:** `publish` prev/stage swap.
**Expected:** prior outdir restored when possible; `ContextPublishFailed`.
**Gap:** host-specific rename atomicity not over-claimed (same family as other Boris publishers).
