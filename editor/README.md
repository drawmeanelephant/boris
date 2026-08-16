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
./editor/scripts/test-publication.sh \
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
- `POST /api/files/probe` compares the open-file fingerprint to disk without
  writing; transient filesystem errors stay in-session;
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

## M3 Boris commands and problems

The host exposes one authenticated `POST /api/commands/run` endpoint backed by
a fixed command allowlist: validate, IR build, HTML build, check, impact,
plan, and recipe-scale.
The UI cannot supply argv or a working directory. Commands run against saved
repository files, so all controls are disabled while the active buffer is
dirty.

IR build diagnostics come only from Boris's `.boris/build-report.json`.
Check and impact consume Boris Documentation Intelligence reports under
`.boris/`. Until the HTML-path machine-readable diagnostics contract lands,
validate and HTML build use a bounded stderr adapter and label source positions
as best-effort. Exit 1 (content), 2 (usage/configuration), and 3 (I/O/system)
remain distinct.

Problems are grouped by content-relative source, severity, and Boris code.
Named buttons navigate to Boris-reported UTF-8 byte positions and copy a
bounded, metadata-only diagnostic packet. Packets contain no source excerpt or
absolute project root. Analysis findings and impact endpoints are displayed as
Boris-owned facts; the editor does not infer either.

The M3 gate adds:

```bash
./editor/scripts/test-diagnostics.sh \
  ./zig-out/bin/boris ./editor/zig-out/bin/boris-editor editor/ui/dist
```

The seeded black-box test compares the host response with Boris's generated
build report, exercises the stderr fallback, and preserves real CLI exits 1,
2, and 3. Playwright covers keyboard invocation, visible voice names,
accessibility grouping, exact UTF-8 navigation, fallback labeling, and packet
copying.

M3 deliberately does not add layout diagnostics, LSP, autofix, arbitrary
commands, source parsing, autosave, or preview serving.

## M4 schema and completion-aware authoring

The source pane exposes an ARIA combobox whose categories are explicit, so it
does not need to parse frontmatter or Markdown. Frontmatter keys, enums, and
bounds come from the canonical `boris-frontmatter-1.schema.json`, embedded
verbatim in the host at build time and checked through the contract adapter.
Entity ids, wiki-link targets, parents, relation kinds/targets, and layout slots
come from a successful Boris `.boris/completion.json` only.

Schema suggestions remain available before an IR artifact exists. Graph-backed
categories then explain that Build diagnostics is required. After a successful
IR build, the UI reloads `completion.json` without restarting. The native source
textarea remains the editing surface; completion insertion is explicit and
undoable, with no typing-time rewrite.

The diagnostics integration gate deep-compares the authoring endpoint with the
canonical schema and a real compiler-generated completion index. Playwright
covers listbox/combobox semantics, arrow/Enter insertion, visible voice names,
schema-only startup, and refresh after a successful graph build.

M4 deliberately does not add a frontmatter grammar, Markdown parser, LSP,
heading-fragment completion, typing-time autocomplete, or editor-owned graph.

## M5 live preview fallback

Until `boris serve` is available, the host runs exactly one fixed preview
command per requested rebuild:

```text
boris build --input content --incremental --html-dir dist
```

An explicit successful save requests that build; authors can also use the
visibly named Rebuild preview button. The host never watches or renders source.
A second ephemeral loopback origin serves the committed `dist/` bytes unchanged
and terminates with the editor process. The preview origin requires its random
session token, validates Host and any supplied Origin, rejects traversal and
symlinks, and uses a port-scoped HttpOnly cookie for generated subresources.

The UI reports idle, running, success, failed, and stale distinctly. Boris's
staged output commit preserves the last valid `dist/` tree after a failed
rebuild; the iframe generation advances only on success. While #421 remains
open, failures show bounded Boris stderr and identify that fallback. Embedded
preview content is sandboxed; a named link opens the exact site origin in a new
tab for full behavior.

The M5 gate adds:

```bash
./editor/scripts/test-preview.sh \
  ./zig-out/bin/boris ./editor/zig-out/bin/boris-editor editor/ui/dist
```

It verifies save/rebuild behavior, byte identity with a plain Boris build,
last-good preservation, loopback/header/token/traversal defenses, real-browser
frame rendering through the host CSP, and server shutdown with the editor.
Playwright covers keyboard/voice names, reload generation, and honest
stale/failure states.

M5 deliberately does not add HMR, CSS injection, a watcher, a daemon, a second
renderer, typing-triggered builds, or editor-side HTML transformation. Replace
this fallback with compiler-owned `boris serve` when #392 lands.

## M6 graph-aware navigation

The Graph pane is a read-only inspector of Boris `.boris/graph.json`, with
relation rows taken from `.boris/completion.json`. The host exposes
`GET /api/graph` and forwards the validated artifact; it does not invent
nodes, edges, or backlinks. Wiki-link tokens in the open buffer are scanned
as `[[id]]` text and resolved against graph entities — the editor does not
parse Markdown.

From the current page the inspector can go to the parent, children, siblings,
outgoing reference/include edges, reverse-index backlinks, and completion
relations. The command palette jumps to an entity by id or title and can run
`boris impact` on the open page. All of those actions are named buttons.

The diagnostics integration gate deep-compares `/api/graph` with the real
compiler-generated `graph.json`. Playwright covers parent/backlink/wiki-link
navigation, title jump, impact-on-this-page, and refresh after a successful
graph build.

M6 deliberately does not add an editable graph database, a second graph
model, heading-fragment navigation, or theme/layout diagnostics.

## M7 Cooklang / restaurant authoring

A content tree of only `.cook` pages is a Cooklang project. Health reports
`input_mode: cooklang`, and every fixed Boris invocation (validate, IR/HTML
build, check, impact, preview) adds `--cooklang`. Mixed trees stay mixed and
fail the way Boris fails; the editor does not guess a dialect.

The Recipe pane is a read-only view of the compiler `recipe` facet on
`graph.json` (IR 0.4.0): ingredients, cookware, timers, string quantities, and
`recipeRef` navigation. `.cook` remains the source of truth. **Scale recipe**
spawns `boris recipe-scale`; the editor does not classify or multiply amounts
([Boris issue 554](https://github.com/drawmeanelephant/boris/issues/554) S3).
Graph diagnostics on `.cook` pages that are not `ECOOKLANG` keep the existing
best-effort confidence and are labeled as approximate (adapted Markdown locus).

The M7 gate adds:

```bash
./editor/scripts/test-cooklang.sh \
  ./zig-out/bin/boris ./editor/zig-out/bin/boris-editor editor/ui/dist
```

M7 / S3 deliberately does not add editor-local scaling, structured write-back,
pantry, `.menu`, shopping lists, or nutrition/allergen claims.

## M8 theme authoring

Opening a `themes/**/*.html` layout shows a Theme pane: closed slots from
`completion.json`, which of those tokens appear in the buffer, theme assets,
and `ILAYOUTSELECTED` findings from the HTML `--report` after Validate or
Build HTML, including fallback winners on targets that have layout rules.

Validate and HTML build now pass `--report .boris/html-build-report.json` so
`ELAYOUT*` and `ILAYOUTSELECTED` are structured problems, not stderr-only.
Preview widths 375 / 768 / 1440 resize the iframe only. The accessibility
list is a review aid and says so.

M8 deliberately does not invent layout-selection evidence, change the layout
model, or claim a Voice Control certification.
