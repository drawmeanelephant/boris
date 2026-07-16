# Semantic relations (IR 0.3)

**Status:** first implementation on the semantic-relations branch; relation-free
inputs remain byte-compatible with the IR 0.2 goldens.

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
- maximum 16 entries per page; maximum target length is the existing entity-ID
  bound;
- duplicate `(kind, target)` tuples are rejected, not silently deduplicated;
- author order is accepted for readability but is not an IR ordering promise.

An empty list is valid and is equivalent to an absent field. A missing or
malformed value is a frontmatter content error. No arbitrary relation kind is
accepted.

## Closed relation vocabulary

The initial vocabulary is deliberately small:

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
- unknown kind or malformed entry → `EFRONTMATTER`;
- relation failures prevent graph freeze and publish no partial IR.

All diagnostics carry the originating page source path and frontmatter line.
HTML, RAG, and Documentation Intelligence must either consume the same
validated relation set or explicitly document that they do not expose semantic
relations; they must not invent a second parser or silently ignore invalid
relations.

## IR 0.3 shape

Adding semantic relations is a deliberate schema break. The compiler must emit
`schemaVersion: "0.3.0"` in `manifest.json`, `graph.json`, and
`build-report.json`, and update its compiler identifier/version policy in the
same change. It must never emit relations while claiming IR 0.2.0.

The `graph.json` root key order becomes:

```text
schemaVersion, frozen, nodes, edges, reverseIndex, nav, relations
```

`relations` is always present on a successful frozen graph, including as an
empty array. Each entry has fixed key order:

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

## Compatibility and products

- IR 0.2 consumers must reject the 0.3 artifact by schema version rather than
  silently dropping `relations`.
- `--no-rag` / `--out` remains the explicit IR path; the bare HTML path does
  not change its output solely because relations exist.
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
