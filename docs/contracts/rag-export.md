# RAG export contract (optional, future)

**Status:** normative **plan** for a future optional export  
**Format id:** `boris-rag`  
**Schema version:** `1` (integer in `catalog_meta.json`)  
**Milestone:** 2 documents the contract; product CLI does **not** implement
content RAG export yet.

RAG is a **future optional export** with explicit schema versioning. It is
**not** required for v0.1 IR acceptance (`.boris/` JSON). When export is
implemented and succeeds, the corpus **must** satisfy this document.

Standalone **source-code** packing (`zig build source-rag` → `source-rag/`) is
a separate tool and is **not** this contract.

---

## Relationship to IR

| Surface | Role |
|---------|------|
| Default v0.1 output | Deterministic JSON IR under `.boris/` ([ir-schema.md](ir-schema.md)) |
| Optional RAG export | Separate corpus tree (`rag/` by default) for LLM retrieval |
| HTML `dist/` | Not default; experimental when present |

Graph validation rules (duplicates, missing parent, self-parent,
satellite-of-satellite, cycles) must match the IR compiler before a successful
RAG export is claimed.

---

## Output tree (planned)

Default root: `rag/` (override with a future `--rag-dir=DIR`).

```text
<rag-root>/
  INDEX.md                 # meta retrieval map (catalog entry)
  UPLOAD-GUIDE.md          # meta upload notes (catalog entry)
  catalog.jsonl            # machine catalog (NOT a catalog entry)
  catalog_meta.json        # machine meta (NOT a catalog entry)
  system/**/*.md           # curated seeds
  content/pages/**/*.md    # content pages (entity_id mirrored)
  graph/
    entity-catalog.md
    relations.md
```

---

## Schema versioning

Emitted on **every successful** RAG export as `catalog_meta.json`:

```json
{"format":"boris-rag","schema_version":1,"boris_version":"<product-version>"}
```

| Field | Type | Notes |
|-------|------|--------|
| `format` | string | Always `boris-rag` |
| `schema_version` | number | Integer; bump when this contract breaks consumers |
| `boris_version` | string | Product version that produced the corpus |

Breaking changes to corpus layout, catalog fields, or title/H1 rules require a
`schema_version` bump.

---

## Determinism (planned)

Identical inputs on the **same host** → **byte-identical** corpus trees.
**Not claimed:** cross-OS bit-identical corpora without multi-OS CI evidence.

### Forbidden in deterministic corpus files

- Wall-clock timestamps
- Random / UUID identifiers
- Absolute filesystem paths
- Hostnames, usernames, environment variables
- Hash-map iteration order as emit order

### Required stable sort keys

| Set | Sort key (ascending, byte-wise) |
|-----|----------------------------------|
| Content pages | `entity_id` (then `source_path` on ties) |
| System seed documents | relative path under system docs dir |
| Graph hubs, satellite lists | `entity_id` |
| `catalog.jsonl` rows | `rag_path` |

---

## `catalog.jsonl` (planned field order)

```text
rag_id, rag_path, category, title, entity_id, role, parent_entry, tags
```

| Field | Content pages | System / graph / meta |
|-------|---------------|------------------------|
| `rag_id` | `content/<entity_id>` | stable id |
| `rag_path` | corpus-relative path | corpus-relative path |
| `category` | `content` | `system` \| `graph` \| `meta` |
| `title` | human title | human title |
| `entity_id` | entity id | `""` |
| `role` | `trunk` \| `satellite` | `""` |
| `parent_entry` | parent id or `""` | `""` |
| `tags` | string form of tag list | string form of tag list |

**Note on `parent_entry`:** this is a **catalog column name** in the RAG
export schema only. Author-facing frontmatter and IR use **`parent`** exclusively
([frontmatter.md](frontmatter.md), [ir-schema.md](ir-schema.md)). The catalog
field stores the same entity-id string; it is not a license to accept
`parentEntry` in source frontmatter.

---

## Aside / `:::kind` export representation

- **Canonical authoring grammar** for asides/admonitions is constrained
  `<Aside …>` component tokens (when the HTML/parse path lands).
- RAG export, when implemented, may inline asides into the parent page as
  directive-style blocks:

```text
:::tip{id="example"}
Body text.
:::
```

- These `:::kind` blocks are an **export representation** for LLM retrieval.
- They are **not** the canonical authoring grammar and are **not** required to
  be round-trippable as input.

---

## Content page title / H1 ownership (planned)

**Model: metadata-owned.**

1. Catalog `title` and the document H1 come from frontmatter `title`, else
   `entity_id`.
2. The exporter emits exactly one ATX H1: `# <title>`.
3. A leading ATX H1 in the source body is **stripped**.
4. Any remaining ATX H1 lines in the body are **demoted to H2**.
5. Therefore each exported content page has **exactly one** document H1.

---

## Out of scope

- Chunking
- Embeddings
- Database storage
- Upload integrations / network clients
- Making RAG the default CLI output
- Treating `:::kind` as authoring syntax

---

## Acceptance (when implementation lands)

1. Export twice into two distinct directories from identical inputs; byte-compare
   every file.
2. `catalog_meta.json` exists and matches the fixed shape above.
3. Each `catalog.jsonl` line parses as JSON with the required keys in order.
4. Deterministic ordering under shuffled fixture creation order.
5. Exactly one ATX H1 per exported content page.
6. Graph validation failures abort export (no partial success claim).
