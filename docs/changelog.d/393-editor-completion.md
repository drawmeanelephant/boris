### Added

- Editor ergonomics (contracts first, no LSP in this slice):
  - The closed frontmatter grammar now has a machine-readable twin,
    [`boris-frontmatter-1.schema.json`](../contracts/schemas/boris-frontmatter-1.schema.json),
    describing the parsed field set as a JSON object (closed key set, typed
    values, normative bounds). The schema-conformance suite validates every
    fixture tree's parsed frontmatter against it.
  - A successful IR build now publishes `completion.json` alongside
    `manifest.json` / `graph.json` / `build-report.json`: a deterministic
    editor completion surface with entity ids (title, parent, role, status,
    tags, relations), the relation-kind vocabulary (canonical plus observed),
    distinct parent targets, and the closed layout-slot set. Schema:
    [`boris-completion-1.schema.json`](../contracts/schemas/boris-completion-1.schema.json).
  - Wiki-link fragment heading ids are Oliver-rendered on the HTML path and
    are documented as out of scope for the IR completion index; the entity id
    list serves the `[[entity#…]]` completion prefix.
