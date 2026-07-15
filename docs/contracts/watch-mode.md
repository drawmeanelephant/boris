# Boris Watch Mode (P3.2) Design Contract

This document defines the normative contract for the opt-in development watch mode in Boris.

## 1. CLI Semantics & Configuration

Watch mode is an opt-in local development feature that monitors source and layout files, triggering deterministic incremental rebuilds.

### Option Signature
- **Flag**: `--watch`
- **Requires**: HTML mode (`--html`, `--html-dir`, or `--target`).
- **Implication**: When `--watch` is specified, `--incremental` is automatically implied/enabled to guarantee fast rebuilding.
- **Conflicts**:
  - `--watch` combined with `--rag` or `--rag-dir` is a usage error (Exit 2).
  - `--watch` combined with `--out` (IR mode) is a usage error (Exit 2).
  - `--watch` without HTML mode is a usage error (Exit 2).

## 2. Watched Roots & Exclusions

One Boris process owns one watch session for a configured HTML build (single
target via `--html` / `--html-dir`, or multi-target via repeatable `--target`).
See [multi-target-isolated-output.md](multi-target-isolated-output.md) for
selective fan-out and multi-root ignore behavior.

### Watched Roots
- **Content Root**: The directory passed to `--input` (default: `content`).
- **Layout Root(s)**: Parent directories of active layout template(s)
  (global `--html-layout` and any `--target-layout` overrides).

### Exclusions (Self-Trigger Protection)
The following directories and files must be explicitly ignored to prevent feedback loops:
- Every configured HTML output root (`--html-dir` or each `--target` output),
  matched with a **path-component boundary** after normalization (so `dist`
  does not match `distribution/…`, and `./dist` is equivalent to `dist`).
- Cache directories as **path components** (e.g. `.boris-cache/`, `.boris/`) — not arbitrary substrings inside content filenames.
- Staging trees (e.g. sibling `{out}.boris-stage`) and temporary atomic files
  (e.g. files ending with `.tmp` or containing `.tmp.`).

Nested output under a watched content root is supported only when exclusion matching is correct; authors should prefer an output tree outside the content root.

### Symlink Policy
- Consistent with the scanner, watch mode **does not follow directory symlinks**.
- Events on symlink files under the content root are ignored, matching scanner rejection semantics.

## 3. Event Handling, Normalization, & Coalescing

### Normalization
- All paths are normalized to use forward slashes `/`.
- Leading `./` and trailing `/` are stripped.
- Files inside the content root are mapped to their relative path within the content root (e.g. `content/guides/intro.md` → `guides/intro.md`), matching `PageDb` and `DependencyIndex` keys. Stripping requires a true path-prefix boundary (`content` does not match `content2/…`).

### Coalescing and Debouncing
- The watch loop coalesces events within a **debounce window** of `100ms` after the first change in a burst is observed.
- When idle (no pending changes), the portable polling backend rescans on a longer **idle interval** (default `500ms`) to limit full-tree scan cost.
- Changed paths are sorted alphabetically for **deterministic logging**. Rebuild dirty-set selection is performed by the existing content-addressed incremental HTML path (fingerprints), not by treating the event list as an affected-set plan.

### Fallback Mapping
- The portable `PollingWatcher` always rescans watched roots and diffs mtimes; platform-ambiguous renames are handled as delete/create or modify pairs rather than guessed dependency edges.

## 4. Rebuild Serialization & Concurrency

- **No Concurrent Builds**: At most one build/rebuild cycle may be active at any time (single-threaded coordinator loop).
- **Serialization**: Filesystem changes that occur during a rebuild are observed on the **next poll** after the active rebuild finishes, producing **one follow-up rebuild** with the newly coalesced set. The coordinator does not run concurrent compiles.
- **Fresh State**: Rebuilds re-run discovery and validation over the fresh state, then use incremental fingerprints to skip unchanged pages when `--incremental` is active (implied by `--watch`).

## 5. Error Recovery & Diagnostics

- **Graceful Failure**: If a rebuild fails due to content validation, frontmatter grammar, components, or layout markers, the error is printed to stderr (unless `--quiet` is set). The watcher **does not exit**; it continues watching so the developer can correct the file and recover.
- **Unrecoverable I/O**: Missing content roots and other hard I/O/system failures exit the process (same policy as a non-watch HTML build), rather than spinning forever on a dead tree.
- **Output Preservation**: A failed rebuild must **never** destroy previously published valid HTML output. This is guaranteed by the atomic file publication mechanism.
- **Successful Recovery**: A subsequent successful build after a correction fully recovers without process restart.

## 6. Shutdown

- **Signals**: Watch mode supports graceful exit on `Ctrl-C` (SIGINT) and `SIGTERM` via an async-signal-safe atomic flag.
- **Cleanup**: On shutdown, the watcher finishes the current rebuild if one is in progress (no mid-render cancel), joins any active parallel HTML workers through the normal compile path, then releases watcher handles and coordinator memory on process teardown.

## 7. Portability

- **Interface**: The watch backend is isolated behind a small, testable `Watcher` interface.
- **Backends**:
  - `FakeWatcher`: An in-memory, **single-threaded** mock backend for deterministic, non-timing-dependent unit and integration tests.
  - `PollingWatcher`: A portable fallback watcher that compares `mtime` and handles recursive trees without kqueue/inotify file-descriptor exhaustion.
