# Semantic relations (IR 0.3)

**Status:** implemented and merged; relation-free inputs remain byte-compatible
with the IR 0.2 goldens.

Semantic relations describe author-intended knowledge relationships. They are
not build dependencies. In particular, a `depends_on` semantic relation must
not dirty or rebuild a page, and an `include` build edge must never appear as a
semantic relation merely because it exists in the dependency graph.

## Authoring grammar

The first syntax is one bounded frontmatter field using an explicit inline
list. It is not YAML and does not open a general nested grammar:

```text
relations: [supersedes=guides/cache-v1, depends_on=reference/cache-manifest]
```

Rules:

- `relations:` is accepted only in the product frontmatter parser;
- the value must be `[` then zero or more comma-separated entries then `]`;
- each entry is `kind=target`, with optional ASCII spaces/tabs around commas
  and the equals sign;
- entries contain no quotes, nested lists, escapes, or additional equals signs;
- targets are canonical page entity IDs in the existing identity namespace;
- maximum 128 entries per page; maximum target length is the existing entity-ID
  bound;
- duplicate `(kind, target)` tuples are rejected, not silently deduplicated;
- author order is accepted for readability but is not an IR ordering promise.

An empty list is valid and is equivalent to an absent field. A missing or
malformed value is a frontmatter content error. Relation kinds must match the
bounded ASCII token grammar `[a-z][a-z0-9_]{0,63}`. Boris preserves these
opaque tokens but does not assign new domain meanings to them.

## Constrained open relation-kind vocabulary

The original names remain valid:

| Kind | Meaning |
|------|---------|
| `relates_to` | The source page is conceptually related to the target. |
| `implements` | The source page describes an implementation of the target concept/specification. |
| `depends_on` | The source page is conceptually dependent on the target knowledge. |
| `supersedes` | The source page replaces or makes the target page obsolete. |

Kinds are directional and are not inferred reciprocally. A relation is not a
navigation edge, parent edge, include edge, or wiki-link reference edge.

## Validation and diagnostics

Validation occurs after page discovery and parent/dependency graph validation,
before IR freeze/publication:

- target not present in the page set → `ERELATIONMISSING`;
- source equals target → `ERELATIONSELF`;
- duplicate tuple → `ERELATIONDUPLICATE`;
- malformed or grammar-invalid kind token or malformed entry → `EFRONTMATTER`;
- relation failures prevent graph freeze and publish no partial IR.

All diagnostics carry the originating page source path and frontmatter line.
The IR pipeline and HTML graph freeze, including `boris validate`, invoke the
same graph-owned semantic-relation validator. HTML exposes relations only
through the explicit slots below. RAG and Documentation Intelligence must
either consume the same validated relation set or explicitly document that they
do not expose semantic relations; no projection may invent a second parser or
silently ignore invalid relations.

## IR 0.3 shape

Adding semantic relations is a deliberate schema break. The compiler must emit
`schemaVersion: "0.3.0"` in `manifest.json`, `graph.json`, and
`build-report.json`, and update its compiler identifier/version policy in the
same change. It must never emit relations while claiming IR 0.2.0.

The `graph.json` root key order becomes:

```text
schemaVersion, frozen, nodes, edges, reverseIndex, nav, relations
```

For artifacts emitted with schema `0.3.0`, `relations` is always present on a
successful frozen graph, including as an empty array. Relation-free artifacts
retain IR 0.2 shape and omit this key. Each entry has fixed key order:

```json
{
  "from": {"type": "page", "value": "guides/cache"},
  "to": {"type": "page", "value": "guides/cache-v1"},
  "kind": "supersedes"
}
```

Semantic relation endpoints use the same `{type,value}` shape as dependency
edges, but both endpoints must have `type: "page"`. `relations` is sorted by
`from.type`, `from.value`, `to.type`, `to.value`, then `kind` using unsigned
byte order. It has no reverse index in IR 0.3; consumers that need reverse
semantic lookup can build one without confusing it with build invalidation.

Opening the constrained kind token grammar does not change this JSON shape:
`kind` remains a string, relation-bearing artifacts remain IR 0.3, and no
schema-version bump is required. A future change to endpoint shape, ordering,
or relation representation would require the normal schema decision.

## HTML presentation

The closed theme vocabulary accepts `{{relations}}` and `{{backlinks}}`.
Each optional slot emits an empty string when its view is empty; Boris does not
add a wrapper around an empty slot.

- `{{relations}}` renders outgoing relations from the current page.
- `{{backlinks}}` derives incoming relations from the same validated set; no
  duplicate backlink authoring is accepted or needed.
- Outgoing entries sort by kind, then target entity id. Backlinks sort by source
  entity id, then kind. Ordering is bytewise and independent of author order or
  worker count.
- Each entry links through the canonical page output path and carries a
  `data-relation-kind` attribute and `semantic-relation--<kind>` class.
- Boris does not infer reciprocal relations, hierarchy/include/wiki/reference
  edges, or meaning from a kind name.

## Incremental HTML behavior

Relations remain distinct from build-dependency edges. A page whose selected
layout uses a relation slot includes page-local relation material—endpoint ids,
kinds, titles, and output paths—in its HTML fingerprint. Changing a relation
therefore re-renders its source and affected backlink targets. A page whose
layout uses neither relation slot includes no relation material and is not
dirtied by unrelated relation changes. This is an HTML planner/cache concern,
not a new IR dependency edge.

## Compatibility and products

- IR 0.2 consumers must reject the 0.3 artifact by schema version rather than
  silently dropping `relations`.
- `--no-rag` / `--out` remains the explicit IR path; the bare HTML path does
  not change its output solely because relations exist. HTML build and
  no-publication validation still reject an invalid relation set before render.
- RAG may later export semantic relations as metadata, but that is a separate
  RAG contract amendment and must preserve the existing `boris-rag` schema.
- Documentation Intelligence may report semantic relations only after its own
  contract is amended; current `check` / `impact` behavior is dependency-only.

## Acceptance fixtures

The first implementation includes fixtures/tests for:

- multiple valid kinds and deterministic canonical order;
- absent `relations` (which remains on IR 0.2);
- malformed list, unknown kind, duplicate tuple, self-target, and missing page
  parser/validation coverage;
- a combined semantic/build-dependency golden proving the arrays remain
  separate;
- old IR 0.2 goldens remaining unchanged while relation-bearing output uses the
  deliberate IR 0.3 schema/version cut.
