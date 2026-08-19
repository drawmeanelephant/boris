# Boris Watch Mode (P3.2) Design Contract

This document defines the normative contract for the opt-in development watch mode in Boris.

## 1. CLI Semantics & Configuration

Watch mode is an opt-in local development feature that monitors source and layout files, triggering deterministic incremental rebuilds.

### Option Signature
- **Flag**: `--watch`
- **Requires**: HTML mode (`--html`, `--html-dir`, or `--target`).
- **Implication**: When `--watch` is specified, `--incremental` is automatically implied/enabled to guarantee fast rebuilding.
- **`boris validate --watch` (issue #647)**: the zero-write validation daemon.
  It reuses this same coordinator — debounce/coalescing, normalization,
  ignore rules, serialization, and signal handling — but every cycle runs the
  one-shot `validate` preflight instead of an HTML publish (action
  `.validate`). It writes nothing except the optional `--report` file, which
  is replaced (never appended) every cycle; `--html-dir`, `--target`,
  `--serve`, and `--port` are usage errors with it because the single
  synthetic `default` target is always preflighted and no output exists.
  NDJSON events carry `mode` `"validate"` (§8); the daemon exits `0` on
  SIGINT/SIGTERM.
- **Flag**: `--watch-json` (watch only; `boris watch --watch-json`, or the flag form `--watch --watch-json`).
  - **Requires**: watch mode; `--watch-json` without `--watch` / `watch` is a usage error (Exit 2).
  - **Implication**: The compile's prose progress and diagnostic stderr are suppressed for the
    lifetime of each build; the same diagnostics flow into the machine-readable `build-failed`
    event instead (§8).
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
- Sibling staging trees for each configured output root only:
  `{out}.boris-stage` and paths under it, matched with a **path-prefix
  boundary** against that root (so `dist.boris-stage/…` is ignored when
  `out=dist`, but author paths such as `content/notes.boris-stage/readme.md`
  or `content/about.boris-stage.md` are **not** ignored by substring).
- Temporary atomic files (e.g. files ending with `.tmp` or containing `.tmp.`).

Nested output under a watched content root is supported only when exclusion matching is correct; authors should prefer an output tree outside the content root.

### Symlink Policy
- Consistent with the scanner, watch mode **does not follow directory symlinks**.
- Events on symlink files under the content root are ignored, matching scanner rejection semantics.

## 3. Event Handling, Normalization, & Coalescing

### Normalization
- All paths are normalized to use forward slashes `/`.
- Leading `./`, trailing `/`, empty segments, and `.` components are collapsed.
  Relative `..` segments pop the previous component when possible so equivalent
  spellings compare equal (`./layouts/main.html`, `layouts/./main.html`, and
  `layouts/main.html` are the same key).
- Files inside the content root are mapped to their relative path within the content root (e.g. `content/guides/intro.md` → `guides/intro.md`), matching `PageDb` and `DependencyIndex` keys. Stripping requires a true path-prefix boundary (`content` does not match `content2/…`). Custom `--input` roots (e.g. `./docs/src`) use the same normalized boundary.
- Layout fan-out compares **normalized** event keys against each target’s
  **normalized** effective layout path (global `--html-layout` or
  `--target-layout`), so spelling variants of the same layout file select the
  same target subset.

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

## 8. `--watch-json` NDJSON Event Stream

`--watch-json` switches the watch process into a machine-readable mode: every
build phase is announced as **one JSON object per line** (NDJSON, UTF-8, LF
after each record, no pretty-printing) on **stderr**. Consumers parse stderr
line-by-line and key off the `event` field. Exit codes are unchanged by
`--watch-json` (0 success, 1 content validation, 2 usage, 3 I/O/system).

### Stream Purity

- The stream is **exclusively NDJSON** while `--watch-json` is active. Compile
  progress prose (`wrote dist/…`) and prose diagnostics are suppressed for the
  duration of each build; the diagnostics are carried inside `build-failed`
  instead. `--quiet` is therefore implied by `--watch-json` for the compile
  path, but the event stream itself is always emitted regardless of `--quiet`.
- Key order is stable and written explicitly, so a consumer may pin the exact
  byte shape. Numeric fields are emitted without quotes; `null` marks an absent
  optional scalar.

### Versioning Handshake

The first record is always `hello`. A consumer must refuse to proceed when
`watch_events_schema` is not the version it understands (mirroring how IR
artifacts gate on `schemaVersion`).

```json
{"event":"hello","watch_events_schema":1,"compiler":"boris/0.8.1"}
```

- `compiler` is the `boris/<version>` compiler identifier.

### Event Types

| event             | when                                                                 |
| ----------------- | -------------------------------------------------------------------- |
| `hello`           | first record; schema handshake                                       |
| `build-started`   | a build/rebuild cycle begins                                         |
| `build-succeeded` | a build/rebuild completes successfully                               |
| `build-failed`    | a build/rebuild fails (recoverable or not)                           |
| `watcher-started` | the poll loop begins after the initial build (even if it failed)     |
| `serve-started`   | `--serve` bound a loopback port (emitted even under `--quiet`)       |
| `watch-error`     | the watch loop hit a non-build error (e.g. poll failure)             |
| `watch-stopped`   | graceful shutdown on SIGINT/SIGTERM; `reason` is `"signal"`         |

Common fields:

- `phase` is `"initial"` for the startup build or `"rebuild"` for a change-triggered build.
- `mode` is `"html"` for the publish daemon or `"validate"` for the
  zero-write validation daemon (`boris validate --watch`, issue #647).
- `targets` is the **subset actually rebuilt** (selective rebuild names only
  the affected targets), never the full configured set; the empty-targets
  single-target path reports the synthetic target `"default"`. Validate mode
  always reports `["default"]` (no target fan-out).
- `changed` (rebuild only) is the coalesced, sorted set of normalized changed
  paths that triggered the rebuild.

`build-started`:

```json
{"event":"build-started","phase":"initial","mode":"html","targets":["default"]}
```

`build-succeeded`:

```json
{"event":"build-succeeded","phase":"rebuild","mode":"html","targets":["default"],"changed":["index.md"],"pages_written":1,"duration_ms":45}
```

- `pages_written` is the number of pages written this cycle (`null` when the
  compile path does not report it — always `null` in `validate` mode, which
  writes nothing); `duration_ms` is the elapsed wall time of the build.

Validate mode uses the same event names with `mode` `"validate"`:

```json
{"event":"build-succeeded","phase":"rebuild","mode":"validate","targets":["default"],"changed":["index.md"],"pages_written":null,"duration_ms":12}
```

`build-failed`:

```json
{"event":"build-failed","phase":"initial","mode":"html","targets":["default"],"errors":1,"diagnostics":[{"severity":"error","code":"EROUTEMISSING","message":"…","remediation":"…","sourcePath":"…","line":null,"column":null,"id":null}],"recoverable":true,"duration_ms":28}
```

- `errors` is the count of `error`-severity diagnostics.
- Each `diagnostics` object is byte-identical in shape and field order to the
  `build-report.json` / `html-build-report-0.1.0` diagnostic object
  (`severity`, `code`, `message`, `remediation`, `sourcePath`, `line`,
  `column`, `id`). `sourcePath` and `id` are `null` when absent; `line` and
  `column` are `null` when not known.
- `recoverable` is `true` when the watcher keeps running to await a correction
  (content/layout validation), `false` when the process will exit (hard I/O).

`watcher-started`, `serve-started`, `watch-error`, `watch-stopped`:

```json
{"event":"watcher-started","mode":"html","targets":["default"]}
{"event":"serve-started","url":"http://127.0.0.1:8090/","helper":"http://127.0.0.1:8090/__boris/","port":8090}
{"event":"watch-error","message":"poll error (BrokenPipe)","recoverable":true}
{"event":"watch-stopped","reason":"signal"}
```

- `serve-started` is the only port discovery for `--serve` consumers: `url` is
  the tree origin, `helper` the auto-reload helper origin, `port` the bound
  loopback port (0 = ephemeral resolves to the actual port).
