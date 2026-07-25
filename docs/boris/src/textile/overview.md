---
title: "`src/textile.zig` overview"
id: docs/boris/src/textile
status: draft
tags: [boris, zig, source-reference, textile]
---

# `src/textile.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/textile/surface-and-execution|Surface and execution]]
* [[docs/boris/src/textile/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/textile/review-state|Review state]]

## Executive summary

`src/textile.zig` is the bounded Textile-to-Markdown body adapter for the Boris compiler. Its sole public function, `toMarkdown`, accepts a post-frontmatter Textile body as a `[]const u8` slice and returns either an allocator-owned Markdown string or a `Diagnostic` value describing the first content error encountered. The module is explicitly declared pure: it performs no filesystem access, makes no Apex calls, has no graph or process access, and does not interact with the pipeline. It converts bytes to bytes in memory, and nothing else.

The file exists because Boris needed an additive input-compatibility slice that could accept `.textile` source files without coupling the format to any Markdown renderer, IR schema change, or new pipeline concept. The adapter translates a deliberately small, closed Textile subset into Markdown that the existing Apex/component/wikilink stages can consume unchanged. The normative contract is `docs/contracts/textile-compatibility.md`, which the module's top-level doc comment cites directly.

The system boundary protected by this module is correctness-of-conversion: Textile content must never silently produce syntactically ambiguous or semantically incorrect Markdown. Every unsupported Textile form, every malformed supported form, and every unsafe link destination is rejected loudly with a `Diagnostic` carrying a 1-based body-relative line and byte column. The adapter never silently falls through to emitting partial or unescaped output.

The module is compiled as a standalone Zig module with its own test executable (`textile_mod` / `textile_tests`) declared in `build.zig`. Its tests run as part of `zig build test` (the default test step), with the working directory set to the repository root so fixture file paths resolve. The module does not link Apex, libc, or any external library. It imports only `std` and `parser.zig` (inside its `expectFixture` test helper). The production binary links this code through the broader pipeline path.

The confidence provided by the existing tests is meaningful but not exhaustive. The golden-fixture tests verify that two specific `.textile` files produce byte-exact expected `.md` outputs, exercising the round-trip path including the parser integration. The rejection table test exercises 14 specific adversarial or unsupported inputs and confirms that each produces a diagnostic whose message contains an expected keyword substring. Three further tests verify: table-declaration rejection with exact line/column; character-escaping correctness on a representative mixed sentence; and determinism (two independent calls on the same input produce equal output).

What the tests do not prove includes: behavior on inputs exceeding available memory (only `OutOfMemory` propagation is observable, not tested); correctness of every inline-escaping combination; correctness of the `readLine` CRLF stripping for inputs ending exactly at a `\r` boundary; column-number accuracy for multi-byte UTF-8 sequences inside inline spans (the module counts bytes, not codepoints, in `base_column` arithmetic); completeness of the `validDestination` allowlist against all plausible edge inputs; and behavior if `parser.zig` returns an error result for the fixture source (the `expect(parsed.isOk())` assertion would fail the test, but the adapter's own response to an upstream parse failure is not independently exercised here).

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Pure Zig library module with co-located tests |
| Conceptual domain | Textile-to-Markdown syntax adaptation; content correctness; diagnostic reporting |
| Build or test root | `src/textile.zig` is the root module of `textile_mod` in `build.zig` |
| Production runtime dependency | Yes — linked into the main Boris CLI via the pipeline import chain; called on `.textile` input when `--textile` mode is active |
| Expected execution command | `zig build test` (default step includes `run_textile_tests`); or `zig build test --step textile` if a targeted alias were added (none currently exists; the test executable is unnamed in the default step) |
| Main collaborators | `src/parser.zig` (fixture helper only), `docs/contracts/textile-compatibility.md` (normative contract), `docs/contracts/fixtures/textile-compatibility/` (golden fixture tree) |
| Documentation depth warranted | High — normative contract exists; module is a named additive feature with explicit dialect boundaries and a broad rejection surface |

***

## Role in the Boris architecture

`src/textile.zig` is a **pipeline pre-stage adapter**: it executes before Apex is ever called. Its position in the documented pipeline is:

```text
scan selected .textile extension
  → parser.zig: extract frontmatter + body offset
  → textile.toMarkdown(body, allocator)  ← this module
      → produces []u8 Markdown or Diagnostic
  → existing component / include / wiki-link validation stages
  → Apex render → IR / RAG / Context / layout splice
```

The module is not a test-only file. It is a library that the production binary depends on whenever `--textile` mode is active. It does not call `src/apex.zig` at any point; Apex only ever sees the produced Markdown, not the Textile source. Apex integration happens downstream and is entirely independent of this module.

The module has no relationship to `apex_hostile_test.zig` or to any hostile C double. It does not cross a C ABI boundary of any kind. Its only non-`std` import is `parser.zig`, and that import appears only inside an `expectFixture` test helper — it is not required at library call sites.

The normal test suite includes this module's tests in `zig build test`. There is no separate opt-in step required, unlike the hostile Apex tests (`test-apex-hostile`) or the sanitizer smoke (`test-apex-sanitize`). This module is also not compiled into the hostile test target.

***
