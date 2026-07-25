---
title: "`src/page.zig` evidence and cases"
id: docs/boris/src/page/evidence-and-cases
parent: docs/boris/src/page
status: draft
tags: [boris, zig, source-reference, evidence, page]
---

# `src/page.zig` evidence and cases

## Tested declarations and entry points

| Test | Kind | Purpose | Inputs / setup | Expected result | Contract exercised |
| --- | --- | --- | --- | --- | --- |
| `pageLessThan sort key entity_id then source_path` | unit | Verifies primary sort key | Three `Page` values with distinct `entity_id` strings `"z"`, `"a"`, `"m"` | After `sortPages`, order is `a`, `m`, `z` | Deterministic discovery ordering by entity id |
| `pageLessThan ties break on source_path` | unit | Verifies secondary sort key for duplicate entity ids | Two `Page` values with identical `entity_id = "dup"` but `source_path` `"b.md"` and `"a.md"` | After `sortPages`, `"a.md"` precedes `"b.md"` | Stable tiebreaker for diagnostics on duplicate ids |
| `Status.parse closed vocabulary` | unit | Verifies exact-string matching for all three variants and rejects non-canonical inputs | Literal strings `"draft"`, `"published"`, `"archived"`, `"Draft"`, `""` | First three return corresponding enum values; last two return `null` | Closed-vocabulary enforcement; case-sensitive; empty string rejected |
| `PageDb.promote owns strings after source buffer free` | ownership | Demonstrates that all string fields promoted from a `FrontmatterView` survive deallocation of the source buffer | Temporary source buffer allocated from GPA, sliced manually into `title_view`, `parent_view`, `tag_a`, `tag_b`; retain arena held separately; source freed after `promote` | All fields on the promoted `DurablePage` remain valid and equal expected strings; `role == .satellite`; tags length and values correct | `PageDb.promote` copies all source-buffer slices into the retain arena before returning; no dangling references |

## Control flow

```text
scanner.zig
    → canonicalEntityId (identity.zig)
    → Page { source_path, entity_id, output_path, kind }
    → PageList.append
    → sortPages (pageLessThan: entity_id asc, source_path tiebreaker)

pipeline.zig
    → for each sorted Page:
        parser.zig → FrontmatterView (slices into source buffer)
                     body_offset
        PageDb.promote(discovery: Page, entity_id, meta: FrontmatterView, body_offset)
            → copy tags → retain arena
            → copy relations → retain arena
            → dupe/safeOutputRelativePath → retain arena
            → DurablePage appended to PageDb.pages
        source buffer may be freed here

graph.zig
    → PageDb.itemsMut()
    → writes role, index, parent_index on each DurablePage
    → freeze

emit/rag/compile phases
    → PageDb.items() (read-only, retain-owned strings, safe)
```
