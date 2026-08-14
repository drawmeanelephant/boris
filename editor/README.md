# Boris Editor

The Boris Editor is a local browser-served authoring environment and a clean
consumer of Boris. The Zig host owns loopback transport, safe local file
operations, session state, and fixed Boris CLI invocations. Boris remains the
only parser, graph, validation, completion, rendering, and publication
authority; Oliver remains the markup authority.

## M0 scaffold

Build the static Svelte UI and the independent Zig host:

```bash
cd editor/ui
npm ci
npm run check
npm run build
cd ../..
zig build
zig build --build-file editor/build.zig test
zig build --build-file editor/build.zig
./editor/zig-out/bin/boris-editor . \
  --boris ./zig-out/bin/boris \
  --ui-dir editor/ui/dist
```

The host binds an ephemeral port on `127.0.0.1`, prints a launch URL containing
a random session token in its URL fragment, and serves:

- `GET /` and `/assets/*`: compiled editor shell;
- `GET /api/health`: host/project-discovery health;
- `GET /api/version`: the result of the fixed `boris --version` invocation and
  the editor's supported artifact-version matrix.

Every API request requires the random token and a loopback `Host`; any supplied
`Origin` must match the session origin. The state-root path is computed from the
canonical project path under the OS user cache directory. M0 does not create
that directory and has no project-content write endpoint. A path-like `--boris`
value is canonicalized against the editor's current directory at startup (so
`./zig-out/bin/boris` keeps working from inside the project); a bare command
name is resolved through `PATH` instead.

The adapter accepts only the published Boris versions for `completion.json`,
`build-report.json`, `manifest.json`, `graph.json`, Documentation Intelligence,
publication plans, and the frontmatter JSON Schema. Compiler identifiers are
opaque and may carry Boris-owned variant suffixes.

## M0 gates

```bash
npm --prefix editor/ui ci
npm --prefix editor/ui run check
npm --prefix editor/ui run build
npm --prefix editor/ui run test:e2e
zig fmt --check editor/build.zig editor/build.zig.zon editor/src
zig build --build-file editor/build.zig test
zig build --build-file editor/build.zig
./editor/scripts/test-contract-fixture.sh \
  ./zig-out/bin/boris ./editor/zig-out/bin/boris-editor-contract-probe
./editor/scripts/test-host.sh \
  ./zig-out/bin/boris ./editor/zig-out/bin/boris-editor editor/ui/dist
```

M0 deliberately does not edit files, display diagnostics, preview a site, or
provide completion UI.

## M2 safe file editing

The safe-editing slice exposes only author-owned project files: `boris.json`
and regular files below `content/` or `themes/`. Generated output, editor state,
absolute paths, traversal, and symlinks are excluded. API reads and mutations
continue to require the loopback session token, valid `Host`, and matching
`Origin` when one is supplied.

The editor now supports explicit open/save, create, no-clobber rename, confirmed
delete, and session-local content undo/redo. Save is never autosave: the host
compares the open-time fingerprint (mtime, size, and content hash), writes a
temporary file in the destination directory, flushes and fsyncs it, and then
atomically renames it. A changed, deleted, or read-only disk file is reported
without replacing it. The conflict dialog keeps both the unsaved editor buffer
and current disk version visible and requires an explicit choice.

Dirty buffers are periodically snapshotted to the disposable OS user-cache
state root. A later editor process labels them as recovered and requires an
explicit Restore or Discard action; recovery data never becomes repository
truth unless the author explicitly saves it.

The authenticated file API is intentionally small:

- `GET /api/files` and `POST /api/files/open` enumerate and open safe files;
- `POST /api/files/save`, `/create`, `/rename`, and `/delete` perform explicit
  project mutations with conflict/no-clobber checks;
- `GET /api/recovery` and `POST /api/recovery/snapshot` or `/clear` manage
  disposable dirty-buffer recovery.

The M2 gate remains the M0 gate list above. Its host integration now exercises
the real filesystem failure paths and a host restart, while Playwright covers
the semantic tree, keyboard shortcuts, visible voice-command names, native
dialogs, conflict comparison, and recovered-state labeling.

M2 deliberately does not invoke Boris, parse frontmatter or Markdown, provide
completion, autosave, Git integration, diagnostics, or preview.
