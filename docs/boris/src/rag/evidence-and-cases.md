---
title: "`src/rag.zig` evidence and cases"
id: docs/boris/src/rag/evidence-and-cases
parent: docs/boris/src/rag
status: draft
tags: [boris, zig, source-reference, evidence, rag]
---

# `src/rag.zig` evidence and cases

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `prepareContentBody` | private fn | Strip leading ATX H1 and demote remaining H1s to H2 | `"# Title\n\nBody.\n"` and multi-H1 variant | Zero remaining H1s; demoted lines contain `## Second` | H1 normalization for RAG export |
| `catalog_meta.json shape is fixed and compact` | test | `exportCatalogMeta` writes a single compact JSON line with `format`, `schema_version`, `boris_version` in that order | tmp dir; `exportCatalogMeta(io, gpa, out_dir)` | Byte-equal to `{"format":"boris-rag","schema_version":1,"boris_version":"…"}\n`; field order verified by index comparison; JSON-parsed values match constants | `catalog_format`, `catalog_schema_version`, `boris_version` constants; field order normative contract |
| `catalog.jsonl field order and string escaping` | test | `exportCatalogJsonl` writes JSONL with correct field order and JSON-escapes `"` and `\n` in title | Single entry with `title: "Say \"hi\"\nthere"` | Exact byte match to expected JSONL line; field-order confirmed by sequential index scan; JSON-parsed `rag_id` matches | Catalog field order; JSON string escaping of double-quote and newline |
| `rag export: valid corpus, dual-run determinism, catalog, H1, system order` | test | Full `run` → file tree; second run to same paths; per-file assertions | Four content files + two system seeds written in reverse order; `run` called twice | `res_a.ok()`; 4 content pages; 2 system docs; required files present; both runs byte-identical; catalog sorted by `rag_path`; system seeds sorted `a-first < b-second`; content sorted `a-first < guides/nested < m-mid < z-last`; exactly 1 ATX H1 per content page; `m-mid.md` has source H1 stripped and inner H1 demoted; `z-last.md` has `:::tip{id="z1"}` not `&lt;Aside`; `INDEX.md` references expected paths | Determinism; sort order; H1 normalization; aside conversion; catalog shape; dual-publish idempotency |
| `rag vs IR: identical diagnostic categories; no graph RAG on failure` | test | Run IR and RAG over `duplicate-ids` fixture; assert no corpus published on failure; prior out dir preserved | Pre-seeded `rag_out` with `stale-marker.txt`; `content = "docs/contracts/fixtures/duplicate-ids/content"` | IR `!ok`; RAG `!compile.ok`; `!stats.published`; every IR diagnostic code present in RAG diagnostics; error count equal; `stale-marker.txt` still present; `catalog.jsonl` absent; `graph/relations.md` absent | Shared compile gate; no corpus on failure; prior output preserved |
| `rag export against fixtures/content/valid` | test | `run` twice on `fixtures/content/valid`; check swap-dir cleanup; validate `catalog_meta.json` and each JSONL line | `docs/rag/system` as system dir; two consecutive `run` calls to same `out` path | Both runs `ok()`; required files present; no `.boris-rag-prev` or `.boris-rag-next` left after second run; `catalog_meta.json` valid JSON with `format: "boris-rag"`; each JSONL line parses as valid JSON | `publishCorpus` move-aside cleanup; catalog JSON validity |

## Control flow — `rag.run`

```text
rag.run(io, gpa, opts)
    → pipeline.compile(io, gpa, compile_opts)
        → scanner.scan
        → parser.parse (per file)
        → aside.tokenizeBody (per file)
        → graph.validate
        → graph.freeze
        → (returns pipeline.Result)
    → if !compile.ok: return result (no staging, no publish)
    → create stage dir ({out_dir}.boris-rag-stage)
    → open stage_dir
        → exportSystemDocs
            → sys_dir.walk → sort rels
            → per rel: readFileAlloc → rag_emit.renderSystemDocument → writeBytes
            → appendCatalog
        → exportContentPages
            → per page (sorted by entity id):
                → readFileAlloc → parser.parse → aside.tokenizeBody
                → rag_emit.renderContentDocument → writeBytes
                → rag_emit.contentCatalogEntry → appendCatalog
        → exportGraphDocs
            → rag_emit.renderEntityCatalog → writeBytes
            → rag_emit.renderRelations → writeBytes
            → appendCatalog (×2)
        → exportUploadGuide → writeBytes (rag_emit.upload_guide literal)
        → appendCatalog (UPLOAD-GUIDE, INDEX)
        → rag_emit.sortCatalogByRagPath
        → exportIndex → rag_emit.renderIndex → writeBytes
        → exportCatalogJsonl → rag_emit.renderCatalogJsonl → writeBytes
        → exportCatalogMeta → rag_emit.renderCatalogMeta → writeBytes
    → close stage_dir (all handles closed)
    → publishCorpus(io, gpa, stage_rel, out_dir)
        → tryRenameDir(stage, out)         ← fast path
        → if fails: move out→prev, rename stage→out, delete prev
        → if fails: copyTreeFiles(stage→next), swap next↔out, cleanup
    → stats.published = true
    → return result
```
