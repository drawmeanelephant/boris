---
title: "`tools/migration-lab/filed.zig` evidence and cases"
id: docs/tools/migration-lab/filed/evidence-and-cases
parent: docs/tools/migration-lab/filed
status: draft
tags: [boris, zig, tools, evidence, migration-lab, filed]
---

# `tools/migration-lab/filed.zig` evidence and cases

## Operational walkthroughs

### Default filed migration

**Invocation:**

```
zig build run -- --mode filed --filed-root path/to/filed-fyi --out tmp/filed-out
```

**Inputs:**
`path/to/filed-fyi/src/content/docs/changelog/` (must contain exactly 1 `.md`/`.mdx` file) and `path/to/filed-fyi/src/content/docs/releases/` (must contain exactly 3 `.md`/`.mdx` files).

**Execution path:**
`main` → `parseOptions` → `.filed` dispatch → `filed.run` → `collectCollection` × 2 → cardinality check → sort → `createDirPath(outdir)` → write index stubs × 2 → write pages × 4 → build manifest + report → write JSON files → optional progress print.

**Outputs:**
`content/changelog/<slug>.md`, `content/releases/<slug>.md` × 3, `content/changelog/index.md`, `content/releases/index.md`, `provenancemanifest.json`, `report.json`.

**Deterministic properties:**
Records sorted by `sourcepath`; slugs derived deterministically from filenames; no timestamps or random values in output.

**Failure behavior:**

- Cardinality violation → `error.UnexpectedCollectionCardinality` → `main` logs and exits 3; no partial output guarantee (output dir may have been created; index stubs may have been written before the page loop).
- Unreadable source file → `error` from `readFileAlloc` → propagates; same partial-output risk.
- Output write failure → propagates; arena is deinited; previous valid output may be partially overwritten.

**Evidence strength:** Structurally checked for the happy path; partial coverage for failure paths.

**Residual gap:** No golden comparison test for the full output of the `mini-filed` fixture. Stale-output behaviour on re-run is not tested.

***

### Cardinality violation

**Invocation:**

```
zig build run -- --mode filed --filed-root path/to/wrong-count --out tmp/out
```

**Inputs:** Source root where the changelog has ≠ 1 file or releases has ≠ 3 files.

**Execution path:** Same as above through `collectCollection`; `run` checks counts and returns `error.UnexpectedCollectionCardinality`.

**Outputs:** Output directory may have been created; no page or manifest files are guaranteed written.

**Evidence strength:** Structurally checked (cardinality condition is in `run`); no dedicated test fixture for wrong-count input.

**Residual gap:** Partial output tree left if `outdir` was created before the check. (The check occurs before any write, so in practice no partial files — but this depends on code order, not a transaction.)

***

### Parent-key normalisation

**Invocation:** Any filed migration run where source files contain `parentEntry:` or `parententry:` keys.

**Execution path:** `collectCollection` → `parseSource` → `normalizeParentKeys` → stores `ParentNormalization` in record → `emitPage` calls `decidedParent` → emits canonical `parent:` if status is `.identity` or `.normalized`; omits `parent:` if `.conflict` or `.invalid`; substitutes collection name if `.missing`.

**Deterministic properties:** `normalizeParentKeys` is a pure function of frontmatter bytes and first-field line number; no external state.

**Evidence strength:** Directly demonstrated — `filed-parent-normalize` and `filed-parent-conflict` fixture suites exist with inline tests.

**Residual gap:** Block-scalar parent values (`|`, `>`, `|-`, `>-`) are explicitly rejected as `.invalid` with reason `"block-scalar-parent-value"`. Other YAML constructs (anchors, flow mappings) are not parsed and would be passed through as opaque strings to `isSafeParentId`, which would likely reject them. This is structurally implied but not explicitly tested.

***

### Help / usage path

**Invocation:** `boris-migration-lab --help` or `boris-migration-lab -h`

**Execution path:** `main` → `parseOptions` → `opts.help == true` → `printUsage` → exit 0.

**Evidence strength:** Structurally checked (in `main.zig`).

**Residual gap:** `filed.zig` has no role in usage output.

***

### Invalid CLI invocation

**Invocation:** `boris-migration-lab --mode filed` (missing `--filed-root`)

**Execution path:** `main` parses options; `.filed` dispatch checks `opts.filed_root_dir orelse` → logs error, calls `printUsage`, exits 2.

**Evidence strength:** Structurally checked.

***

## Control flow

```text
process entry (main.zig: main)
    → collect process args
    → parseOptions → .filed dispatch
    → guard: outdir != filed_root_dir
    → filed.run(io, gpa, RunOptions)
        → output-inside-source guard (string prefix check)
        → ArenaAllocator init (gpa)
        → open source root dir (read-only)
        → collectCollection(changelog)
            → openDir src/content/docs/changelog/
            → iterate: for each .file ending in .md/.mdx
                → readFileAlloc
                → parseSource (frontmatter + body split)
                    → normalizeParentKeys (parent-key scan)
                → stripUntrustedBlocks (fence removal)
                → slugAlloc (filename → slug)
                → append Record to list
        → collectCollection(releases) [same]
        → cardinality check (1 changelog, 3 releases)
        → sort records by sourcepath
        → createDirPath(outdir)
        → open outdir
        → for each Collection: writeFile index stub
        → for each Record: writeFile emitPage output
        → count parent-norm statuses
        → build provenancemanifest.json buffer
        → build report.json buffer
        → writeFile provenancemanifest.json
        → writeFile report.json
        → optional progress print
        → arena.deinit (implicit via defer)
    → exit 0
```


***

## Tests, fixtures, and evidence coverage

| Test or fixture | Scope | Property demonstrated | Evidence strength | Not demonstrated |
| :-- | :-- | :-- | :-- | :-- |
| `test "filed mini-filed fixture"` (inline, in `filed.zig` or `main.zig`) | Full `run` call on `fixtures/mini-filed` | Happy-path output structure; parent identity/missing cases | Directly demonstrated | Exact byte identity; stale-output cleanup |
| `fixtures/filed-parent-normalize/` | `normalizeParentKeys` via `run` | `identity`, `normalized` statuses; camelCase and snake_case rewrites | Directly demonstrated | Conflict within normalize fixture |
| `fixtures/filed-parent-conflict/` | `normalizeParentKeys` via `run` | `conflict`, `missing`, `invalid` statuses; unsafe values; empty values; traversal values | Directly demonstrated | Oversize parent value edge case |
| `isSafeParentId` inline unit tests | Pure function | Entity-id shape rules: empty, too long, leading/trailing dash/dot, `..` segment, spaces, slashes | Directly demonstrated | Unicode above ASCII; all reserved characters |
| `fixtures/fm-review-open-fence/` | `stripUntrustedBlocks` indirectly | Open fence flagged but not crashed | Directly demonstrated | Multi-level nested fences |
| `fixtures/fm-review-mixed-content/` | `stripUntrustedBlocks` | Instruction/directive/agent blocks stripped from body | Directly demonstrated | Interaction with parent normalisation in same file |
| Cardinality constraint | Not tested with wrong-count fixture | — | Uncertain | No dedicated wrong-count test |
| Stale output on re-run | Not tested | — | Uncertain | — |
| Symlink in source collection dir | Not tested | — | Uncertain | — |
| Allocation-failure paths | Not tested | — | Uncertain | — |
| Cross-platform byte identity | Not tested | — | Uncertain | — |
| Output-inside-source guard | Structurally enforced; not fixture-tested | — | Partial coverage | Symlink-based bypass |

*Note: Test declarations are inline in `filed.zig` and/or `main.zig`; their exact locations cannot be confirmed with certainty from the source-RAG pack alone for all cases. The fixture directories listed are confirmed present in the catalog.*

***
