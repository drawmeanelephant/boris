---
title: "`src/context.zig` surface and execution"
id: docs/boris/src/context/surface-and-execution
parent: docs/boris/src/context
status: draft
tags: [boris, zig, source-reference, surface, context]
---

# `src/context.zig` surface and execution

## Authoring / operator model

| Flag / option | Effect |
| :-- | :-- |
| `--context` | Mode on; default outdir `context` |
| `--context-dir DIR` | Outdir override |
| `--input DIR` | Content root (must be **relative**; absolute → `AbsoluteContentRoot`) |
| `--scope VALUE` | Entity id or collection prefix; invalid/empty/`..` → `InvalidScope` |
| `--split-size BYTES` | Cap for part packing; null → no `parts/` |
| `--textile` | Whole-tree Textile input format through pipeline |
| `--quiet` | Suppress progress logs |

**Scope semantics (via `exportscope`):** seed match on exact id or `id/` prefix; one-hop semantic neighbors; then transitive parent closure. Ordinary Markdown links do **not** expand scope. Manifest still records **`graph_scope: full`** and full `graph_page_count` because `graph.json` is the complete validated graph, not the projection.

## Published layout

```text
{outdir}/
  bundle.md              # TOC + concatenated page docs (entity-id order of selection)
  graph.json             # pipeline.renderGraph of full compile
  manifest.json          # format, versions, counts, digests, optional parts index
  pages/{entity-id}.md   # one provenance document per selected page
  parts/part-N.md        # only when --split-size set and chunks exist
```

Staging: `{outdir}.boris-context-stage` → rename to outdir; on failure restore `{outdir}.boris-context-prev` when needed; `errdefer` deletes stage.

## Key types

| Type | Role |
| :-- | :-- |
| `format` | `"boris-context"` |
| `schema_version` | `u32 = 1` |
| `ContextOptions` | `content_root`, `outdir`, `quiet`, `input_format`, `scope`, `split_size` |
| `ContextResult` | embeds `pipeline.Result`; `published`, `selected_pages`, `graph_pages`, `relation_count`, `part_count`, `chunk_count`; `ok` = compile.ok ∧ published |
| `PageArtifact` | node view + `source_hash` + `page_hash` + owned `page_doc` |
| `ContextChunk` | per-piece page doc for split path + number/count + source sha |
| `ContextPart` | concatenated chunk docs under byte cap + first/last chunk indices |
| `ContextChunkInfo` | number/count for YAML `part:` frontmatter |

## Public API surface

| Symbol | Kind | Purpose |
| :-- | :-- | :-- |
| `format` / `schema_version` | pub const | Manifest identity |
| `ContextOptions` | pub struct | Run configuration |
| `ContextResult` | pub struct | Outcome + stats; `deinit` / `ok` |
| `run` | pub fn | Compile → render → stage → publish |

Internal helpers (not pub product API): `renderPageDoc` / `WithChunk`, `renderBundle`, `renderParts`, `renderManifest`, `renderContextChunks`, `publish`, path/IO helpers, relation/schema id selectors.

## Integration with CLI / pipeline

| Layer | Behavior |
| :-- | :-- |
| `cli` | Mode `.context`; defaults `context` dir; conflicts with HTML/IR/RAG flags |
| `main.runContext` | Maps `InvalidScope` / `OversizedBlock` → content exit 1; other errors → IO exit 3; prints compile diagnostics when present |
| `pipeline.compile` | Sole validation gate; failed compile never publishes |
| `exportscope` | Shared with RAG for scope + Markdown partition |
| `cache.hexDigest` | Stable hex of SHA-256 over raw bytes |

## Ownership and allocation

| Resource | Owner | Notes |
| :-- | :-- | :-- |
| `pipeline.Result` / arena | `ContextResult.compile` | Source bytes for pages live in compile arena |
| `page_doc` / chunk `doc` / part `doc` | GPA until free after write | Freed on `run` defers |
| Graph/bundle/manifest buffers | GPA, freed after stage write |  |
| Stage tree | FS | Removed on errdefer; renamed away on success |
| Graph node slices in artifacts | Views into compile arena | Must not outlive `ContextResult` without compile |

No global mutable state. Single-threaded export.

## Path security and fail-closed rules

| Case | Handling |
| :-- | :-- |
| Absolute content root | `AbsoluteContentRoot` before compile |
| Invalid scope (empty, `..`, missing id) | `InvalidScope` from `selectPages` |
| Compile content errors | `published=false`; no stage install |
| Indivisible block > split cap | `OversizedBlock`; stage cleaned; prior outdir preserved if publish never started |
| Publish rename failure | Restore prev tree; `ContextPublishFailed` |
| Partial stage write | `errdefer deleteTree(stage)` |
| Semantic relations | Only from validated nodes; not re-parsed from Markdown |

## Diagnostics and exit mapping

Context does not define `diag.Code` printers of its own. Failures surface as:

- Pipeline diagnostics (unchanged codes) when compile fails
- Export errors: `InvalidScope`, `OversizedBlock`, `InvalidBodyOffset`, `AbsoluteContentRoot`, `ContextPublishFailed`, IO/OOM

`main` treats scope/oversize as **content** failures (exit 1); most else as **IO** (exit 3).

## What this file does not do

- HTML/Oliver rendering, layouts, themes, content-local assets
- RAG catalog/INDEX/system seeds or `--bundles-only`
- Independent content discovery or frontmatter parsing
- Watch/incremental context rebuilds
- Fetching remote content or calling LLM APIs
- Token estimation (`split-size` is **bytes**, not tokens)
- Claiming graph.json is scope-filtered
