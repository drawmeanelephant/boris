---
title: "`src/context.zig` overview"
id: docs/boris/src/context
status: draft
tags: [boris, zig, source-reference, context]
---

# `src/context.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/context/surface-and-execution|Surface and execution]]
* [[docs/boris/src/context/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/context/review-state|Review state]]

## Executive summary

`src/context.zig` implements the **deterministic AI Context Bundle** export path. It reuses `pipeline.compile` and `pipeline.renderGraph` so discovery, frontmatter, graph validation, and IR schema identity stay single-sourced. After a successful compile it projects selected pages (optional `--scope` via `exportscope.selectPages`), reads each page’s source bytes, emits provenance-rich per-page Markdown documents, a single concatenated `bundle.md`, the full-site `graph.json`, a machine `manifest.json` with SHA-256 digests, and optional upload `parts/part-N.md` chunks when `--split-size` is set. Publish is stage-then-rename with previous-tree restore on failure; failed stages are deleted so a later run cannot treat partial output as its own staging area.

The module is deliberately an **export surface**, not a second parser. It does not walk content independently, does not rebuild parent edges, does not run Apex/HTML, and does not invent entity ids. Semantic-relation IR schema/compiler ids are chosen only when the validated graph actually carries relations. Chunking reuses `exportscope.partitionMarkdown` (blank-line / heading boundaries outside fences) with a deterministic header budget so oversized indivisible blocks fail closed (`OversizedBlock`) without replacing a prior successful export.

Primary production entry is `context.run`, wired from `main.runContext` for CLI mode `.context` (`--context` / `--context-dir`, optional `--scope`, `--split-size`). Unit tests cover chunk provenance/fences and scoped manifests marking `graph_scope` as full. Normative product contract: Context Bundle docs referenced from README/CHANGELOG (v0.4.0+).

Confidence is high for compile reuse, artifact layout, hash provenance, scope + full-graph policy, split/part math, and atomic publish. Gaps: absolute `content_root` rejected (relative-only); Windows rename edge cases follow host FS; no streaming of huge sources (full file in memory); Textile body offset path depends on pipeline page metadata.

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Production library module with embedded unit tests |
| Conceptual domain | AI context export; provenance Markdown; scoped graph projection; split upload parts |
| Build or test root | Linked via product CLI / `pipeline` consumers; tests via `zig build test` |
| Production runtime dependency | Yes — CLI `--context` / `--context-dir` mode only |
| Expected execution command | `boris --context` or `boris --context-dir DIR [--scope ID] [--split-size N]`; `zig build test` |
| Main collaborators | `pipeline.zig` (compile + renderGraph), `exportscope.zig` (selectPages, partitionMarkdown), `cache.zig` (hexDigest/hashBytes), `jsonout.zig` (escape/usize), `identity.zig` (InputFormat), `graph.zig` (Node), `main.zig` / `cli.zig` |
| Documentation depth warranted | High — upload contracts, scope vs full graph, and fail-closed split behavior are easy to misuse |

## Role in the Boris architecture

```text
content/**  ──► pipeline.compile (scan/parse/validate/freeze)
                    │
                    ├─ full pages[] ──► graph.json (always full validated graph)
                    │
                    └─ exportscope.selectPages(scope?)
                              │
                              ▼
                    page docs + bundle.md + optional parts/
                              │
                              ▼
                    manifest.json (hashes, counts, scope metadata)
                              │
                              ▼
                    stage → atomic publish → context/ (or --context-dir)
```

- **Product binary:** `main.runContext` → `context.run`; exclusive of HTML/IR/RAG modes at CLI parse time.
- **vs RAG (`rag.zig` / `ragemit.zig`):** both share compile + scope/split ideas; context emits a **human/agent Markdown bundle** with source fences and SHA-256 provenance, not the RAG corpus layout (`INDEX.md`, `catalog.jsonl`, system seeds). Context has no `--bundles-only`.
- **vs `llms.zig`:** llms is a thin discovery map; context is a full provenance pack.
- **vs HTML `compile.zig`:** no layouts, Apex, assets, or incremental cache.
- **Byte size (bundle):** ~23212 bytes packed source document.
