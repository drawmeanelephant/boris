---
title: "`tools/migration-lab/frontmatter_review.zig` evidence and cases"
id: docs/tools/migration-lab/frontmatter_review/evidence-and-cases
parent: docs/tools/migration-lab/frontmatter_review
status: draft
tags: [boris, zig, tools, evidence, migration-lab, frontmatter_review]
---

# `tools/migration-lab/frontmatter_review.zig` evidence and cases

## Operational walkthroughs

### Default frontmatter-review scan

**Invocation:**

```
zig build run -- --content ./content --out ../fmreview-out
```

**Inputs:**
All `.md` and `.mdx` files under `./content` (recursively, skip dirs applied).

**Execution path:**
`main` → `parseOptions` → `frontmatterreview.run` → `collectFiles` → sort → per-file `scanFile` → `emitJson` + `emitMd` → write two files.

**Outputs:**
`../fmreview-out/frontmatterreview.json`, `../fmreview-out/FRONTMATTERREVIEW.md`. Both written unconditionally.

**Deterministic properties:**
File order in output is lexicographic on content-root-relative path. Key order within a file follows source line order. Demonstrated by inline and fixture tests.

**Failure behavior:**

- `--content` equals `--out`: exit 2, stderr message from `main.zig`.
- `sourceRoot` directory not openable: `error.FileNotFound` propagated as exit 3.
- Unreadable file inside content tree: `openFile` error propagated as exit 3; partial output risk.
- `outDir` creation or write failure: exit 3; partial output risk.

**Evidence strength:** Directly demonstrated for unit logic; fixture tests exercise the full I/O path.

**Residual gap:** No test for partial-failure output state. No test for unreadable files inside the content tree.

***

### Clean content tree (all Boris keys only)

**Invocation:**

```
zig build run -- --content fixtures/fm-review-no-unknown --out fixtures/test-fmreview-no-unknown
```

**Outputs:**
`frontmatterreview.json` with `"files": []` (or `totalOccurrences: 0`); `FRONTMATTERREVIEW.md` containing "None".

**Evidence strength:** Directly demonstrated by `test fixture fm-review-no-unknown`.

**Residual gap:** The fixture test checks content via `indexOfStr`; no byte-for-byte golden comparison.

***

### Mixed content tree (some unknown keys)

**Invocation:**

```
zig build run -- --content fixtures/fm-review-mixed --out fixtures/test-fmreview-mixed
```

**Outputs:**
`frontmatterreview.json` with populated `files` array; `FRONTMATTERREVIEW.md` with per-file tables.

**Evidence strength:** Directly demonstrated by the `test fixture …` (mixed fixture referenced in `test parseOptions frontmatter-review flags` which uses `fixtures/fm-review-mixed`).

**Residual gap:** The exact fixture content and golden expected output were not directly inspected; coverage is inferred from the test structure.

***

### Unclosed frontmatter fence

**Invocation:** Any file in the content tree with `---` opening but no closing `---`.

**Outputs:** That file appears in both JSON and Markdown output with `incompatibleFence: true`. Zero `unknownKeys` entries for that file (the scanner returns early before collecting keys when the fence is unclosed).

**Evidence strength:** Directly demonstrated by `test scanFile unclosed fence sets incompatibleFence`.

**Residual gap:** No test verifies that such a file's body bytes are unaffected.

***

### Help path

**Invocation:** `zig build run -- --help`

**Outputs:** Usage to stderr (via `std.debug.print`), exit 0.

**Evidence strength:** Directly demonstrated by `test parseOptions defaults and astro flags` checking `opts.help`.

***

### Invalid CLI invocation

**Invocation:** `zig build run -- --mode frontmatter-review` (no `--content`).

**Outputs:** Stderr message from `main.zig`: "frontmatter-review mode requires --content DIR", then usage, exit 2.

**Evidence strength:** Structurally enforced by `main.zig`; not tested by a direct CLI error test for this specific condition.

***

## Control flow

```text
process entry (main)
    → initialize arena + gpa from std.process.Init
    → collect process arguments
    → parseOptions → mode = .frontmatterReview, opts.contentDir set
    → guard: --out must differ from --content (exit 2 if same)
    → frontmatterreview.run(io, gpa, {sourceRoot, outDir, quiet})
        → guard: OutputInsideSource check
        → arena init from gpa
        → Io.Dir.cwd.openDir(sourceRoot) → sourcedir
        → collectFiles(io, a, sourcedir, "", &entries)
            → recursive Dir.iterate
            → skip dirs by name + hidden-dir rule
            → append WalkEntry{relpath} for .md/.mdx files
        → std.mem.sort(WalkEntry, lexicographic on relpath)
        → for each entry:
            → sourcedir.openFile(relpath)
            → allocRemaining → raw bytes
            → scanFile(a, raw)
                → check opening ---
                → find closing --- with strict validation
                → line scan: skip blank/indented/list lines
                → for key:value pairs: if !isBorisKey → append KeyOccurrence
            → if occurrences.len == 0 and !incompatibleFence: continue
            → accumulate allKeyNames (deduplicated), reviews
        → build ScanResult
        → Io.Dir.cwd.createDirPath(outDir)
        → Io.Dir.cwd.openDir(outDir) → out
        → emitJson(a, result) → JSON bytes
        → out.writeFile("frontmatterreview.json", jsonBytes)
        → emitMd(a, result) → Markdown bytes
        → out.writeFile("FRONTMATTERREVIEW.md", mdBytes)
        → if !quiet: std.debug.print summary
    → return ExitCode.success.int()
```


***

## Tests, fixtures, and evidence coverage

| Test or fixture | Scope | Property demonstrated | Evidence strength | Not demonstrated |
| :-- | :-- | :-- | :-- | :-- |
| `test scanFile all Boris keys are not flagged` | Unit | Boris grammar keys produce zero occurrences | Directly demonstrated | Non-ASCII keys; very long keys |
| `test scanFile unknown keys are captured with line numbers` | Unit | Line numbers 1-based from fence-open; key/value capture; 3 keys | Directly demonstrated | Keys at frontmatter line 1 (opening fence) |
| `test scanFile no frontmatter returns empty` | Unit | Files without `---` produce zero results and no fence flag | Directly demonstrated | Empty file; binary file |
| `test scanFile unclosed fence sets incompatibleFence` | Unit | Missing closing `---` → `incompatibleFence: true`; zero occurrences | Directly demonstrated | CRLF fence; fence with trailing spaces |
| `test scanFile list item lines under tags are skipped` | Unit | `- alpha` lines under `tags` are not parsed as keys | Directly demonstrated | Deeply nested YAML; indented key-value lines |
| `test escapeMdCell pipe is escaped` | Unit | `|` → `&#124;` | Directly demonstrated | Backslash; HTML entities in input |
| `test escapeMdCell newlines become spaces` | Unit | `\n` in value → space | Directly demonstrated | `\r\n`; `\r` alone |
| `test escapeMdCell plain string is unchanged` | Unit | Clean strings pass through | Directly demonstrated | — |
| `test emitJson unknownKeys array present and ordered` | Unit | JSON contains format, schemaVersion, key names; source order preserved | Directly demonstrated | Field ordering across all fields; totalUnknownKeys distinctness |
| `test emitMd section headers and table present` | Unit | Markdown has expected headers and file path | Directly demonstrated | FRONTMATTERREVIEW.md full structure test |
| `test emitMd pipe in value is escaped in table cell` | Unit | `&#124;` present in output | Directly demonstrated | Pipe in key name |
| `test emitMd no-unknown case says None` | Unit | Empty result → "None" in output | Directly demonstrated | — |
| `test fixture fm-review-no-unknown` | Integration (I/O) | Full `run` path; JSON and MD written; MD says "None" | Directly demonstrated | File ordering; output overwrite; stale cleanup |
| `test parseOptions frontmatter-review flags` (in `main.zig`) | CLI unit | Mode set correctly for all three aliases; `--content` sets `contentDir` | Directly demonstrated | `--out` == `--content` path guard |

**Not demonstrated:**

- Byte-for-byte repeated-run determinism check (no two-run golden comparison).
- Path safety under adversarial filenames.
- Behavior on very large files or deeply nested content trees.
- Stale-output cleanup (not implemented and not tested).
- Windows path separator behavior.
- Allocation failure paths.
- Cross-platform CI coverage (not confirmed from available evidence).

***
