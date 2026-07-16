# AI Context Bundle contract (implemented)

**Status:** first implementation
**Format:** `boris-context`
**Schema version:** `1`

An AI Context Bundle is a deterministic, provenance-rich projection of a
validated Boris content graph. It is intended for uploading to a chat LLM or
feeding a local retrieval tool. It is not a replacement for the HTML site, IR,
or product RAG corpus.

## CLI and output

`--context` selects context-only export under `context/`; `--context-dir DIR`
selects context-only export under `DIR`. The flags cannot be combined with HTML,
IR, or RAG selectors.

Successful output contains:

```text
<context-dir>/
  bundle.md       # one uploadable, ordered Markdown document
  manifest.json   # format, graph/version, page and artifact provenance
  graph.json      # the validated Boris graph, including IR 0.3 relations
  pages/<id>.md   # one provenance-prefixed source segment per page
```

The exporter calls `pipeline.compile` and publishes nothing when validation
fails. It does not parse frontmatter or graph edges independently.

## Determinism and provenance

- Pages are ordered by canonical entity id.
- Semantic relations retain the graph's canonical relation ordering.
- No timestamps, random identifiers, absolute paths, hostnames, or environment
  values are emitted.
- Every page record contains the canonical `entity_id`, source-relative
  `source_path`, graph role, parent, semantic relations, and lowercase SHA-256
  of the exact source bytes used for the bundle.
- `manifest.json` records the bundle schema, product/compiler id, IR schema,
  content-root label, page count, relation count, and generated artifact paths.
- Markdown source is fenced with a dynamically sized backtick fence so source
  content cannot terminate its own provenance section.

The `content_root` field is the caller-provided relative label. Absolute input
roots are rejected for bundle metadata rather than leaking host paths.

## Compatibility

Context schema version `1` is independent of `boris-rag` schema `1` and IR
schema versions. A relation-bearing graph remains identifiable as IR 0.3 in
`manifest.json` and `graph.json`; relation-free graphs retain IR 0.2.

Invalid content is a content failure (exit `1`) and leaves the previous context
directory untouched. I/O failures use exit `3`.
