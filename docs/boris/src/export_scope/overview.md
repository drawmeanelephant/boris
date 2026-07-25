---
title: "`src/export_scope.zig` overview"
id: docs/boris/src/export_scope
status: draft
tags: [boris, zig, source-reference, export_scope]
---

# `src/export_scope.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/export_scope/surface-and-execution|Surface and execution]]
* [[docs/boris/src/export_scope/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/export_scope/review-state|Review state]]

## Executive summary

`src/export_scope.zig` is a pure-Zig utility module that provides two independent but complementary operations needed by both the RAG export path (`src/rag.zig`) and the AI context bundle path (`src/context.zig`): graph projection via `selectPages`, and deterministic Markdown body partitioning via `partitionMarkdown`. Neither function performs I/O, accesses the filesystem, calls the pipeline, or touches the ApexMarkdown C ABI. The module is a shared computation layer that sits between the validated pipeline output and the final export serializers.

`selectPages` takes a frozen, pipeline-validated slice of `graph.Node` values together with an optional scope string, and returns a caller-owned filtered subset. The filtering logic implements a three-phase closure: first, an exact-id or prefix-match seed; second, a one-hop semantic neighbor closure over `semanticRelations`; and third, a transitive structural (parent-chain) closure that runs after the relation projection. The function enforces a strict set of syntactic rules on the scope string itself — rejecting empty strings, strings beginning with `.`, and strings containing `..` or `/` — and returns `error.InvalidScope` for any violation, including a valid-looking scope that matches no page.

`partitionMarkdown` takes a raw Markdown body string and a caller-supplied byte budget, and splits the body into the minimum number of non-overlapping contiguous pieces each within that budget, splitting only at blank-line or heading boundaries outside fenced code. It is explicitly not a Markdown parser: it detects fence lines by scanning for opening ```` ``` ```` or `~~~` sequences and tracking their character and minimum-length state across lines, and it defers all semantic interpretation of Markdown to the pipeline. If no safe split boundary exists within the budget window, it returns `error.OversizedBlock`. If the entire body fits in one piece, no split is attempted.

The file exists because both `rag.zig` and `context.zig` need the same scope-projection logic and the same chunk-splitting logic, and encoding it in either caller would duplicate the rules and tests. Extraction into a shared module allows both callers to delegate the scoping and partitioning contracts without depending on each other or on the pipeline. The module has no production runtime dependency on anything other than `std` and `src/graph.zig`.

All tests are inline and cover: collection-plus-parent-plus-semantic-neighbor selection; rejection of malformed scope selectors; fence-preservation under partitioning; OversizedBlock on indivisible input; and split correctness across paragraphs and headings. The tests are exercised via `zig build test` through whatever step imports the module. The file is not itself a test root.

What this file does not prove: it does not demonstrate that `selectPages` preserves ordering (the source confirms preservation of the original `pages` slice order via index-filtered append, but no test asserts sort stability explicitly); it does not test the two-hop transitive closure termination behavior under cycles (the pipeline upstream guarantees cycle-freedom before this function receives its input); and it does not test that `partitionMarkdown` produces a globally minimal partition count — it produces a greedy left-to-right partition, and no test verifies that the count is minimal.

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Shared utility library module |
| Conceptual domain | Export scope projection; deterministic Markdown chunking |
| Build or test root | No — imported by `rag.zig` and `context.zig`; tests run via the main test step |
| Production runtime dependency | Yes — called on both the `--rag` and `--context` CLI paths |
| Expected execution command | `zig build test` (unit tests inline); exercised indirectly by integration tests in `rag.zig` and `context.zig` |
| Main collaborators | `src/graph.zig` (type `graph.Node`); `src/rag.zig` (`selectPages`, `partitionMarkdown`); `src/context.zig` (`selectPages`, `partitionMarkdown` via `renderContextChunks`) |
| Documentation depth warranted | Medium — small file (~8 KB), two public functions, well-tested inline, but the closure semantics and the fence-tracking state machine both warrant careful exposition |

***

## Role in the Boris architecture

`src/export_scope.zig` is not linked into a special test binary. It is an ordinary library module compiled as part of the production binary whenever `src/rag.zig` or `src/context.zig` are linked. It is not a main file and has no `pub fn main`.

In relation to the overall pipeline:

- **Product binary**: Compiled into the `boris` binary through `rag.zig` and `context.zig`, which are reachable from `src/main.zig` on the `--rag` and `--context` execution paths respectively.
- **`src/apex.zig`**: No relationship. `export_scope.zig` operates on already-rendered graph nodes after all Markdown processing has completed. It never calls into the ApexMarkdown C ABI.
- **`src/graph.zig`**: The only non-standard import. `selectPages` consumes `graph.Node` slices, reading `.id`, `.parent`, `.semanticRelations`, and `.sourcePath` fields. It does not modify any node.
- **`src/rag.zig`**: Primary caller of both `selectPages` and `partitionMarkdown`. Confirmed in `context.zig` source: `const export_scope = @import("export_scope.zig");` with calls to `export_scope.selectPages(...)` and `export_scope.partitionMarkdown(...)`.
- **`src/context.zig`**: Also imports and calls both public functions. `selectPages` is used to filter the page list before artifact rendering; `partitionMarkdown` is called inside `renderContextChunks` to split a page body against the `splitSize` budget.
- **Normal test suite** (`zig build test`): The inline tests in this file participate in the main test step. No separate hostile or sanitizer step is defined for this module in `build.zig`.
- **Specialized ABI validation**: None. The module has no C interop.

The module is *not* compiled only for tests. It is a production dependency. Removing it would break both the RAG and context export pipelines.

***
