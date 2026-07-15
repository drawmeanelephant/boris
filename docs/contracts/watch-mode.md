# Boris Watch Mode (P3.2) Design Contract

This document defines the normative contract for the opt-in development watch mode in Boris.

## 1. CLI Semantics & Configuration

Watch mode is an opt-in local development feature that monitors source and layout files, triggering deterministic incremental rebuilds.

### Option Signature
- **Flag**: `--watch`
- **Requires**: HTML mode (`--html` or `--html-dir`).
- **Implication**: When `--watch` is specified, `--incremental` is automatically implied/enabled to guarantee fast rebuilding.
- **Conflicts**: 
  - `--watch` combined with `--rag` or `--rag-dir` is a usage error (Exit 2).
  - `--watch` combined with `--out` (IR mode) is a usage error (Exit 2).
  - `--watch` without `--html` or `--html-dir` is a usage error (Exit 2).

## 2. Watched Roots & Exclusions

One Boris process owns exactly one watched target/output root.

### Watched Roots
- **Content Root**: The directory passed to `--input` (default: `content/`).
- **Layout Root**: The parent directory of the template file passed to `--layout-path` (default: `layouts/`).

### Exclusions (Self-Trigger Protection)
The following directories and files must be explicitly ignored to prevent feedback loops:
- The HTML output directory (`--html-dir`, default: `dist/`).
- Cache directories (such as `.boris-cache/`).
- Staging and temporary atomic files (e.g. files ending with `.tmp` or containing `.tmp.`).

### Symlink Policy
- Consistent with the scanner, watch mode **does not follow directory symlinks**.
- Events on symlink files under the content root are ignored or trigger a clean fallback, matching scanner rejection semantics.

## 3. Event Handling, Normalization, & Coalescing

### Normalization
- All paths are normalized to use forward slashes `/`.
- Paths are made relative to the current working directory.
- Files inside the content root are mapped to their relative path within the content root (e.g. `content/guides/intro.md` -> `guides/intro.md`), matching `PageDb` and `DependencyIndex` keys.

### Coalescing and Debouncing
- To handle bursts of filesystem events (such as multiple writes or multi-file renames), the watch loop coalesces events within a **debounce window** of `100ms` (by default, adjustable or fixed for stability).
- Changed paths are sorted alphabetically before planning to guarantee deterministic ordering.

### Fallback Mapping
- For platform-ambiguous events (such as complex renames), the watcher falls back to a full scan of the affected tree rather than guessing stale dependency edges.

## 4. Rebuild Serialization & Concurrency

- **No Concurrent Builds**: At most one build/rebuild cycle may be active at any time.
- **Serialization**: If filesystem events arrive while a rebuild is already in progress, those events are queued/coalesced. Once the active rebuild finishes, a **single follow-up rebuild** is executed with the queued changes. This ensures that no changes are missed, and we avoid compounding build loops.
- **Fresh State**: Rebuilds re-run discovery and validation over the fresh state to prevent operating on an invalid or partially updated graph.

## 5. Error Recovery & Diagnostics

- **Graceful Failure**: If a rebuild fails due to content validation, frontmatter grammar, or layout markers, the error is printed to stderr (unless `--quiet` is set). The watcher **does not exit**; it continues watching so the developer can correct the file and recover.
- **Output Preservation**: A failed rebuild must **never** destroy previously published valid HTML output. This is guaranteed by the atomic file publication mechanism.
- **Successful Recovery**: A subsequent successful build after a correction fully recovers without process restart.

## 6. Shutdown

- **Signals**: Watch mode supports graceful exit on `Ctrl-C` (SIGINT) and `SIGTERM`.
- **Cleanup**: On shutdown, the watcher stops accepting events, finishes or cancels the current rebuild safely, waits for/joins any active worker threads, and releases all watcher handles and resources cleanly.

## 7. Portability

- **Interface**: The watch backend is isolated behind a small, testable `Watcher` interface.
- **Backends**:
  - `FakeWatcher`: An in-memory, thread-safe mock backend for 100% deterministic, non-timing-dependent unit and integration tests.
  - `PollingWatcher`: A highly robust, portable fallback watcher that compares `mtime` and handles recursive trees without kqueue file-descriptor exhaustion.
