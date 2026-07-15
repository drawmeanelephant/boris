# Bounded Parallel HTML Rendering Contract

This document defines the normative behavior, constraints, CLI options, and failure-handling requirements for Boris's bounded parallel HTML rendering path.

## Scope

- Bounded parallelism applies **exclusively** to the rendering and publishing of independent HTML pages under the HTML site mode (`--html` / `--html-dir`).
- **All** other pipeline phases—specifically:
  - content discovery,
  - frontmatter parsing,
  - include / layout dependency resolution,
  - graph validation and freezing,
  - dependency-edge sorting and reverse-index construction,
  - content-addressed cache fingerprinting,
  - and affected-set calculation
  MUST remain strictly single-threaded, executed sequentially by a single coordinator before any worker begins.

## Command Line Semantics

### The `--jobs` Option

- Parallelism is enabled via the optional `--jobs N` or `--jobs=N` flag (short flag: `-j N` or `-j=N`).
- `N` must be a valid, positive integer in the range `[1, 64]`.
- If `--jobs` is omitted, the default is `1` (strict sequential rendering).
- If `N` is outside the range `[1, 64]`, or if the value is malformed (e.g. non-numeric, negative, empty), the compiler MUST reject the input and exit with **Exit Code 2 (Usage Error)**.
- If `--jobs` is provided without `--html` or `--html-dir`, the compiler MUST reject the configuration as a conflict and exit with **Exit Code 2 (Usage Error)**.

## Thread & Memory Isolation

1. **Immutable Inputs:** The resolved graph (including Feature 8 dependency
   edges/reverse index), frozen `PageDb` metadata, layout template, and
   pre-computed `is_dirty` set are completely immutable once workers are spawned.
2. **Independent Output Paths:** Workers write exclusively to unique, non-overlapping destination paths (guaranteed by the safe output path module).
3. **Whiteboard Allocation:** Each worker thread owns its own `std.heap.ArenaAllocator` ("Whiteboard") for page-local rendering. No thread may access or share another thread's `ArenaAllocator`.
4. **Lifetime Contract:** A worker's local `ArenaAllocator` MUST only be reset (`.free_all`) after the `renderAndPublishPage` function has fully returned and all buffered output bytes have been completely flushed and published.

## Determinism & Stable Ordering

To guarantee byte-identical, stable, and reproducible results across successive runs:
- **Output Bytes:** The final `.html` output file contents must be byte-for-byte identical to sequential rendering.
- **Cache Manifest:** The final `.boris-cache/manifest.json` file MUST be updated and written sequentially by the coordinator after all threads join, preserving deterministic, alphabetically sorted order by entity ID.
- **Diagnostics and Logs:** All stdout/stderr progress logs (e.g., `wrote ...` or `cached ...`) and diagnostic reports MUST be printed in stable, deterministic plan order. Workers must not write directly to stdout/stderr.

## Failure & Cancellation Policy

On any rendering or write failure:
- **Stop Scheduling:** The coordinator and other threads MUST stop scheduling new pages.
- **Worker Join:** The coordinator MUST block and wait (`join`) for all currently running workers to complete before returning.
- **Cleanup:** Only the failing operation's temporary files (created via `createFileAtomic`) are discarded. Prior successfully published files MUST remain intact. No intermediate corrupt or partially written files may be promoted.

## Apex concurrency (D4) — mitigated for product options

Workers call in-process Apex via thread-local Whiteboards and a stack-scoped
allocator. Boris does **not** claim a full formal proof that every ApexMarkdown
global (extension registry, optional plugin paths) is re-entrant under
simultaneous `apex_render` calls. Product default keeps plugins/includes/
highlighters off (`vendor/apex/apex.c`).

**Host serialization:** `apex.render` holds a process-wide mutex around the C
`apex_render` entry point. Parallel `--jobs` workers still own independent
Whiteboards and output paths; only engine entry is serialized. This is a
correctness fence for the current pin, not a claim that Apex is lock-free.

**CLI default remains `--jobs 1` (sequential).** `--jobs N` is supported and
smoke-validated for the product Apex configuration; it is not the silent
default, so single-thread builds stay the conservative path.

### Permanent evidence gates (not formal proofs)

- `src/apex.zig` **U18** — concurrent Unified renders vs sequential baselines +
  cross-talk markers
- `src/compile.zig` — `compilePages: parallel Unified constructs stable under
  jobs (D4)` — seq vs `--jobs 8` byte-identical site HTML + dual parallel runs

If either gate fails, treat concurrent Apex as broken for the pin under test.
Do not advertise “fully proven thread-safe Apex” in marketing copy.
