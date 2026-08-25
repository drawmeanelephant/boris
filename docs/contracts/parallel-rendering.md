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

## Renderer concurrency (D4)

Workers render through the Oliver seam (`src/render.zig`) with thread-local
Whiteboards. Oliver is a pure library: no global state, no extension
registries, no hidden caches, no clock/network/filesystem access, and nothing
retained between documents, so simultaneous renders on independent arenas are
safe. The process-wide C-engine mutex the previous renderer required is gone;
see [oliver-renderer.md](oliver-renderer.md).

**CLI default remains `--jobs 1` (sequential).** `--jobs N` is supported and
smoke-validated; it is not the silent default, so single-thread builds stay
the conservative path.

### Measured scope and expected ceiling (#731)

Workers parallelize page render+publish only. Every other phase — discovery,
parse, graph validate, dependency resolution, fingerprinting, heading
harvest, search/sitemap projection, link audit, inventory, checks, claims,
touches, and proof pack — runs sequentially before or after the worker pool,
by the scope rule above. Wall-clock benefit therefore follows Amdahl's law:
`--jobs N` accelerates only the `render` slice of a build.

On a fixed 5,000-page / ~28 MB corpus (ReleaseSafe, 2026-08), the phase
profile was approximately: render ~1.9 s of ~7.3 s serial total; `--jobs 8`
cut render to ~0.7 s for ~2.7× phase speedup, while total wall time improved
only ~1.25× (7.3 s → 5.8 s) because the contractually sequential phases
dominated. Sites with heavier per-page rendering (larger bodies, more
includes) see proportionally more benefit; small sites see almost none.

Dependency resolution previously rebuilt its doclink source map per page,
which made that sequential pre-pass O(pages × nodes) and masked even the
render-phase gains. It now builds one shared map per pass through the same
#726 seam the renderer uses; output bytes are unchanged.

### Permanent evidence gates

- `src/compile.zig` — `compilePages: parallel constructs stable under jobs
  (D4)` — seq vs `--jobs 8` byte-identical site HTML + dual parallel runs
- `src/render.zig` — dual-render byte-identical determinism test

If either gate fails, treat concurrent rendering as broken for the pin under
test.
