---
title: "`src/textile.zig` review state"
id: docs/boris/src/textile/review-state
parent: docs/boris/src/textile
status: draft
tags: [boris, zig, source-reference, review-state, textile]
---

# `src/textile.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Accuracy notes and uncertainties

The following properties are **not mechanically enforced or proven** by the current test suite:

- **Column accuracy for multi-byte UTF-8**: `base_column` arithmetic adds byte positions, not codepoint counts. A diagnostic column reported for a character inside a multi-byte UTF-8 sequence will be the byte offset, not the display column. The contract says "1-based byte column within the original Textile line", so this matches the spec — but it is worth noting for editor-integration consumers.
- **`readLine` lone-CR behavior**: A `\r` not followed by `\n` passes through to `convertInline` and is rejected as a control character. This is structurally correct but not directly tested.
- **`OutOfMemory` behavior**: `toMarkdown` returns `error.OutOfMemory` unmodified. The intermediate `ArrayList(u8)` is cleaned up via `errdefer out.deinit(allocator)`. No test exercises OOM paths.
- **Fixture file existence**: `readTestFile` errors immediately if a fixture file is missing. The test passes only if the fixture tree is present at the expected paths under `docs/contracts/fixtures/textile-compatibility/`. The fixture content is not inspected in this dossier (inaccessible within tool limits); its structure is assumed to be consistent with the contract.
- **`parser.zig` integration correctness**: The fixture tests depend on `parser.parse` succeeding. If the parser produces an incorrect `bodyOffset` (e.g., splitting mid-character), `toMarkdown` receives a misaligned slice. This cross-module dependency is not tested in isolation here.
- **`appendMarkdownByte` completeness**: The backslash-escape set includes `-`, `|`, `~`, `!`, `+`, `{`, `}`. Whether this set is exactly the minimal necessary set for all Markdown-producing renderers is a contract claim, not a mechanically proven property.

***

## Potential follow-up work

> This section is separated from the evidence analysis. These are observations, not assertions about existing defects.

- A test for the reverse list-adjacency case (ordered → unordered) would improve symmetry.
- Tests for unclosed phrase modifiers on each of `_`, `-`, `+`, `@` in addition to `*` would make the modifier-rejection surface explicit.
- A test exercising `&#91;&#91;wikilink&#93;&#93;` at block level (the `&#91;&#91;` branch of the macro-injection check) would close the gap left by the `&#123;&#123;` test.
- A test for CRLF-terminated input would document the `\r\n` stripping behavior.
- The determinism test uses a fixed body; a property-based or fuzz test would provide stronger evidence across the input space (the adjacent `src/fuzz.zig` module may already cover this — not verified within the scope of this dossier).
- Diagnostic column values for multi-byte UTF-8 inputs could be documented with an explicit test, confirming that byte offset (not codepoint offset) is the intended and observable behavior.
