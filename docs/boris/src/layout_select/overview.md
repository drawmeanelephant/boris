---
title: "`src/layout_select.zig` overview"
id: docs/boris/src/layout_select
status: draft
tags: [boris, zig, source-reference, layout_select]
---

# `src/layout_select.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/layout_select/surface-and-execution|Surface and execution]]
* [[docs/boris/src/layout_select/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/layout_select/review-state|Review state]]

## Executive summary

`src/layout_select.zig` is the pure logic layer that translates a `(entity_id, role, rule_table, fallback_layout)` tuple into a resolved layout path for each page in a Boris HTML build. It defines every data type and algorithm needed for the `--layout-rule` CLI surface: the closed `SelectorKind` enum (`id`, `glob`, `role`), the `LayoutRule` struct, path and selector grammar validators, the glob-matching engine, the four-tier precedence selector (`selectLayout`), a duplicate-selector guard, a canonical sort for deterministic digests, a declared-layout collector, and a digest-material serializer. It does not read the filesystem, does not call the Zig allocator unless returning owned memory, and has no dependency on the Apex Markdown engine, frontmatter parser, or graph system.

The file exists to enforce the contract that every layout assignment in a Boris build is deterministic, rejectable at parse time rather than silently at render time, and independent of argv ordering. These three properties are the central commitments of `docs/designs/page-layout-selection-rfc.md` and `docs/contracts/templating-and-themes.md §4` (both referenced in the module docstring; those documents were not inspected directly, so claims about their specific wording are uncertain). The system boundary this file protects is the gap between a raw `--layout-rule` CLI token and a validated, stable layout path that the downstream HTML assembler can open without further checking.

Execution occurs in two modes. The in-file `test` blocks run via `zig build test` as part of the main test suite; they exercise the pure selector logic without any filesystem or compiler integration. A companion file, `src/layout_select_hostile_test.zig`, exercises the same public API under adversarial conditions and also drives full HTML compile rounds through `compile.compileHtmlSite` and `compile.compileHtmlSiteMulti`. The hostile test is invoked by both `zig build test` and the dedicated `zig build test-layout-hostile` step (per the hostile test module docstring).

The in-file tests confirm the closed grammar properties—layout-path lexical rejection, selector parse rules, glob segment matching, four-tier precedence, disambiguation, duplicate rejection, and declaration-order independence—but they do not compile HTML, touch the filesystem, write manifests, or exercise incremental or multi-target scenarios. Those gaps belong entirely to `src/layout_select_hostile_test.zig`. The combined evidence from both files directly demonstrates the properties claimed by the module docstring, but not `MixedThemeRoots` enforcement (which lives in `src/target.zig`) or the CLI `--layout-rule` parse path (which lives in `src/cli.zig`).

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production library module (pure logic, no I/O) |
| Conceptual domain | Layout selection; CLI rule surface; page templating |
| Build or test root | Imported by `compile.zig`, `cli.zig`, `target.zig`; test root for in-file tests via `zig build test` |
| Production runtime dependency | Yes — linked into the boris binary via compile/pipeline |
| Expected execution command | `zig build test` (in-file tests); `zig build test-layout-hostile` (hostile suite) |
| Main collaborators | `src/identity.zig` (entity-id validation, `max_entity_id_bytes`), `src/page.zig` (`Role` enum), `src/layout_select_hostile_test.zig` (hostile/integration coverage), `src/compile.zig` (call site), `src/cli.zig` (parse site), `src/target.zig` (`rejectMixedThemeRoots`, `effectiveLayout`) |
| Documentation depth warranted | High — public API surface with a closed contract used across the production pipeline |

## Role in the Boris architecture

`layout_select.zig` is a pure computation module that sits between CLI/config parsing and HTML page assembly. The product binary includes it at compile time through its imports in `compile.zig`, `cli.zig`, and `target.zig`; there is no runtime dynamic linking. It contains no `main`, no build step, and no file handles.

Within the pipeline, the call flow is approximately: `cli.parseOptions` calls `parseSelector` and `validateLayoutPath` to validate `--layout-rule` tokens at argument-parse time and populates `TargetSpec.layout_rules` slices. During compilation, `compile.compileHtmlSite` (or its multi-target variant) calls `rejectDuplicateSelectors` as a preflight check, then calls `selectLayout` once per page to resolve the effective layout path, which is then opened by the HTML assembler. `ruleTableDigestMaterial` is called during incremental builds to produce the cache-invalidation key for the rule table.

There is no connection to `src/apex.zig` or the ApexMarkdown C ABI. `layout_select.zig` is not a hostile-test target in the sense of `src/apex_hostile_test.zig`; it is a pure Zig module tested against adversarial *usage patterns* (ambiguous globs, traversal paths, permuted rule tables, missing files) rather than against a hostile external C implementation. Its companion hostile test file, `src/layout_select_hostile_test.zig`, provides integration-level coverage by running full compile rounds.
