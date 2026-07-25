---
title: "`src/rag_emit.zig` evidence and cases"
id: docs/boris/src/rag_emit/evidence-and-cases
parent: docs/boris/src/rag_emit
status: draft
tags: [boris, zig, source-reference, evidence, rag_emit]
---

# `src/rag_emit.zig` evidence and cases

## Tested declarations

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| --- | --- | --- | --- | --- | --- |
| `"catalog JSONL field order and escaping are stable"` | `test` | Verifies byte-exact JSONL serialization including escaping of `"` and `\n` in `title` | Single `CatalogEntry` with `title = "Say \"hi\"\nthere"`, `parent_entry = ""` | Exact string: `{"rag_id":"content/quote","rag_path":"content/pages/quote.md","category":"content","title":"Say \"hi\"\\nthere","entity_id":"quote","role":"trunk","parent_entry":"","tags":"[content, trunk]"}\n` | Fixed key order; `json_out.escapeAppend` correctness for `"` and `\n`; empty `parent_entry` emitted; trailing newline present |

All other public functions (`renderSystemDocument`, `renderContentDocument`, `renderEntityCatalog`, `renderRelations`, `renderIndex`, `contentCatalogEntry`, `renderCatalogMeta`, `sortCatalogByRagPath`) have no tests embedded in this file. Their correctness is covered only by integration tests in the broader test suite (if any), or by manual inspection.

***

## Control flow

```text
Caller (rag.zig or equivalent)
    │
    ├─ renderSystemDocument(gpa, rag_id, rag_path, tags, body)
    │      → appendSlice YAML frontmatter header
    │      → appendSlice body verbatim
    │      → ensure trailing newline
    │      → toOwnedSlice → caller owns []u8
    │
    ├─ renderContentDocument(gpa, scratch, page, pages, rag_id, rag_path, segments)
    │      → renderBody(segments, scratch)
    │            for each .markdown segment:
    │                stripLeadingAtxH1(markdown)    ← sub-slice, no alloc
    │                demoteAtxH1ToH2(result, scratch) ← alloc from scratch
    │            for each .aside:
    │                aside.formatRagDirective(value, scratch)
    │            for each .details:
    │                aside.formatDetailsRagDirective(value, scratch)
    │            → toOwnedSlice(scratch) → body []u8 (scratch-owned)
    │      → formatTags(scratch, page.tags)
    │      → build related: block (scratch ArrayList)
    │      → build final doc (gpa ArrayList)
    │      → toOwnedSlice(gpa) → caller owns []u8
    │
    ├─ renderEntityCatalog(gpa, pages)
    │      → fixed header appendSlice
    │      → for each page: print table row
    │      → toOwnedSlice(gpa)
    │
    ├─ renderRelations(gpa, pages)
    │      → fixed header
    │      → trunk-hub sections (input order)
    │      → collect satellite pairs
    │      → sort pairs (src, tgt)
    │      → emit edge list block
    │      → toOwnedSlice(gpa)
    │
    ├─ renderCatalogJsonl(gpa, catalog)
    │      → for each entry:
    │            appendSlice literal key fragments
    │            json_out.escapeAppend for each string value
    │            appendSlice "}\n"
    │      → toOwnedSlice(gpa)
    │
    └─ renderIndex(gpa, catalog, stats, version)
           → YAML front matter + counts table
           → generated artifacts table (fixed)
           → full catalog table (from entries)
           → schema section with inline version
           → toOwnedSlice(gpa)
```


***
