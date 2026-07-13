# Acceptance (planning)

Mechanical acceptance for the content compiler is deferred until pipeline
implementation. Milestone 2 acceptance is:

1. Normative contracts exist and use a single parent key name (`parent`).
2. Fixture inventory covers critical graph and parser error categories.
3. `src/fixtures_test.zig` passes (manifest + file presence only).
4. `zig build test` passes.
5. README distinguishes implemented vs planned behavior.

Normative behavior lives in:

- [frontmatter.md](frontmatter.md)
- [identity-and-paths.md](identity-and-paths.md)
- [diagnostics.md](diagnostics.md)
- [ir-schema.md](ir-schema.md)
- [rag-export.md](rag-export.md)

Fixture inventory: [`../../fixtures/manifest.json`](../../fixtures/manifest.json).
