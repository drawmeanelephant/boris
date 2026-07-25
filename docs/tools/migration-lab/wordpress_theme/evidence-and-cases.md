---
title: "`tools/migration-lab/wordpress_theme.zig` evidence and cases"
id: docs/tools/migration-lab/wordpress_theme/evidence-and-cases
parent: docs/tools/migration-lab/wordpress_theme
status: draft
tags: [boris, zig, tools, evidence, migration-lab, wordpress_theme]
---

# `tools/migration-lab/wordpress_theme.zig` evidence and cases

## Operational walkthroughs

### Default wordpress-theme analysis

**Invocation:**

```
zig build run -- --mode wordpress-theme --root fixtures/mini-wordpress-kubrick --out ../wp-theme-report
```

**Inputs:**

- All files under `fixtures/mini-wordpress-kubrick/` (PHP templates, `style.css`, images).
- No network, no subprocess.

**Execution path:**

- `main.zig:main` → `parseOptions` → dispatch to `wordpresstheme.run`.
- `run` → `refuseOutputInsideSource` → `walkTree` → `scanPhp` per `.php` file → `scanStyle` for `style.css` → sort → create `--out` → emit all six files.

**Outputs:**

- `inventory.json`: all file records + all signals, sorted.
- `slotmapping.json`: hardcoded slot proposal.
- `manualreview.json`: all `unsupported` or `templaterelationship` signals with source lines.
- `prototypemain.html`: static slot-marked HTML shell.
- `report.json`: counts and policy.
- `REPORT.md`: human-readable table and signal list.

**Deterministic properties:**
File and signal sort orders are unconditionally applied. SHA-256 hashes are content-derived. No timestamps. Byte-identical on repeated runs: directly demonstrated by inline test.

**Failure behavior:**

- `--root` not found → `error.SourceNotFound` → exit 3.
- `--out` inside `--root` → `error.OutputInsideSource` → exit 3.
- Unreadable PHP file → silently skipped (no signal, file still inventoried).
- Output directory creation failure → `error.IoFailure` → exit 3.
- Individual `writeBytes` failure → `!void` propagates → exit 3 via `main`.

**Evidence strength:** Directly demonstrated (determinism and signal presence by inline test; classifier by unit test).

**Residual gap:** Behavior on symlinks in source tree, behavior with very large PHP files, cross-platform byte identity not tested.

### Usage / help path

**Invocation:** `boris-migration-lab --help`

**Execution path:** `main.zig:main` → `parseOptions` sets `opts.help = true` → `printUsage()` → returns `ExitCode.success.int()`.

**Outputs:** Usage text to stderr (via `std.debug.print`). No files written.

**Evidence strength:** Directly demonstrated by `parseOptions defaults and astro flags` test (checks `--help` flag parsing).

### Invalid CLI invocation

**Invocation:** `boris-migration-lab --mode wordpress-theme` (no `--root` — defaults to `.`; if `.` equals `--out`, fails; otherwise proceeds with cwd as root).

**Invocation (root equals out):** `boris-migration-lab --mode wordpress-theme --root ./theme --out ./theme`

**Execution path:** `main.zig` checks `std.mem.eql(u8, opts.rootdir, opts.outdir)` → prints error to stderr → returns `ExitCode.usage.int()`.

**Outputs:** Stderr message. No files written.

**Evidence strength:** Structurally checked (guard is inline in `main`).

### I/O failure path

**Invocation:** `--root` points to an unreadable or nonexistent directory.

**Execution path:** `run` → `Io.Dir.cwd.openDir(opts.rootdir)` fails → returns `error.SourceNotFound` → `main` prints `std.log.err("migration-lab wordpress-theme failed: {s}", ...)` → exit 3.

**Evidence strength:** Structurally checked (error propagation); not directly tested.

## Control flow

```text
process entry (main.zig:main)
    → initialize arena allocator, gpa, io
    → collect process arguments (toSlice)
    → parseOptions → Mode.parse → Options struct
    → if opts.help → printUsage → exit 0
    → switch opts.mode → .wordpresstheme
        → check rootdir != outdir (else exit 2)
        → wordpresstheme.run(io, gpa, opts)
            → refuseOutputInsideSource(rootdir, outdir)
            → arena.allocator()
            → open rootdir as Io.Dir
            → walkTree(io, arena, root, "", &files)
                → for each entry: recurse dirs (skip isSkippedDir), append FileRec
            → std.mem.sort(FileRec, files.items, fileLess)
            → for each file: if isText → scanPhp or scanStyle → append Signals
            → std.mem.sort(Signal, signals.items, signalLess)
            → createDirPath(outdir)
            → open outdir as Io.Dir
            → writeBytes(inventory.json, emitInventory(...))
            → writeBytes(manualreview.json, emitManualReview(...))
            → writeBytes(slotmapping.json, emitSlots(...))
            → writeBytes(prototypemain.html, emitPrototype(...))
            → writeBytes(report.json, emitReport(...))
            → writeBytes(REPORT.md, emitReportMd(...))
            → if !quiet: print progress
        → on error: log + exit 3
    → exit 0
```

## Tests, fixtures, and evidence coverage

| Test or fixture | Scope | Property demonstrated | Evidence strength | Not demonstrated |
| :-- | :-- | :-- | :-- | :-- |
| `classifyTemplate classic WordPress hierarchy` | Unit — `classifyTemplate` | Correct classification of 11 canonical filenames + 1 generic PHP + 1 asset | Directly demonstrated | Non-ASCII filenames, mixed-case extensions beyond `style.css` |
| `fixture mini-wordpress-kubrick deterministic inventory and review preservation` | Integration — `run` × 2, all 6 output files | Byte-identical output on repeated runs; `registernavmenus`, `dynamic_sidebar`, `templaterelationship` in inventory; `wp_footer`, `wp_enqueue_script` in manualreview; slot markers in prototype | Directly demonstrated | Cross-platform; hostile filenames; large files; symlinks; allocation failure; failure paths |
| `mini-wordpress-kubrick` fixture (source) | Fixture — synthetic | Models classic WordPress theme structure (index.php, single.php, etc.) | Directly demonstrated | Authentic Kubrick; full WordPress API coverage |
| `refuseOutputInsideSource` (via `themematerialize.zig`) | Unit — boundary guard | Refuses `..` escape and prefix containment; accepts valid relative path | Directly demonstrated | Symlink bypass; trailing-slash normalization |

No golden comparison tests exist for `inventory.json` content beyond substring checks. No test for unreadable files, empty tree, very large files, I/O failure mid-run, or cross-platform byte identity.
