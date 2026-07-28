### Fixed

- RAG corpus documents now encode page-controlled values for the container they
  are written into. A `tags` item can no longer close the YAML flow sequence and
  inject top-level keys such as `category: system` into a document that ships to
  a knowledge base, and a `title` containing `|` can no longer forge extra
  columns in the `INDEX.md` and `graph/entity-catalog.md` tables. Output for
  content without these characters is byte-identical to before.

### Added

- `src/encode.zig` and `src/structured_out.zig`: a shared output-encoding layer
  for machine-facing emitters, with per-container targets (YAML scalar, YAML
  flow-sequence item, markdown table cell, markdown heading, markdown block
  text, and XML text/attribute for a future feed emitter). `structured_out.Sink`
  only accepts `comptime` template text on its literal path, so a runtime value
  cannot reach an emitter unencoded without the explicit, greppable
  `rawTrusted` opt-out. JSON escaping continues to live in `json_out.zig`; the
  sink delegates to it rather than duplicating it.
