### Added

- Published JSON Schema (draft 2020-12) for the three IR artifacts under
  `docs/contracts/schemas/`, so consumers no longer hand-roll parsers from the
  prose contract. `docs/contracts/ir-schema.md` remains normative.
- `zig build test-ir-schema` validates freshly emitted IR against each published
  schema and fails on drift in either direction — a required property the
  emitter dropped, or a property the emitter added that the schema does not
  describe. Included in the aggregate `zig build test`.
