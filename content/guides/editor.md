---
title: Boris Editor
parent: guides/overview
status: published
tags: [guides, editor, authoring, completion, preview]
---

<p class="eyebrow">Authoring surface</p>

# Boris Editor: compiler-backed authoring {#boris-editor}

The Boris Editor is a local, browser-served authoring environment for Boris
projects. It is not another Markdown tool with its own opinions about meaning:
it is a thin interaction layer over the compiler. Boris remains the only
parser, graph, validation, completion, rendering, and publication authority,
and Oliver remains the markup authority. The editor owns interaction only.

This guide covers the advanced surface: safe project editing, schema- and
graph-aware completion, compiler-backed commands and problems, and live
preview. Each capability is deliberately grounded in Boris artifacts — the
editor never re-derives meaning from prose.

<Aside kind="info">

The editor is an **authoring** surface: generated output (`dist/`, `.boris/`),
editor state, and anything outside `boris.json`, `content/`, and `themes/` are
intentionally excluded from file operations. See
[Safe project editing](#safe-project-editing) below.

</Aside>

---

## Launching the editor

The editor host is a separate Zig binary (`boris-editor`) that spawns the
fixed Boris CLI. Build both from the repository:

```bash
zig build                                   # builds ./zig-out/bin/boris
zig build --build-file editor/build.zig     # builds editor/zig-out/bin/boris-editor
```

Launch it against a project directory with the built compiler and UI:

```bash
./editor/zig-out/bin/boris-editor . \
  --boris ./zig-out/bin/boris \
  --ui-dir editor/ui/dist
```

The host binds an ephemeral port on `127.0.0.1` and prints a launch URL whose
URL **fragment** carries a random session token. Open that URL in your browser;
every API request must repeat the token, and any supplied `Origin` must match
the session origin. A bare `--boris` command name is resolved through `PATH`;
a path-like value is canonicalized against the directory you launched from.

`Ctrl+K` (or `Cmd+K`) opens a command palette for file actions, Boris
commands, preview rebuild, and jumping to a project file. Esc, the palette's
**Cancel** button, or a click on the dimmed backdrop closes it without running
anything.

- [[guides/cli-and-modes|CLI and modes]] — the compiler surface the editor drives
- [[guides/themes-and-layouts|Themes and layouts]] — what `Build HTML` produces

---

## Safe project editing

Saving is explicit and never automatic. The host compares the open-time
fingerprint (mtime, size, and content hash) against disk before writing: it
writes a temporary file in the destination directory, flushes and fsyncs it,
then atomically renames it into place.

- **Open / save** — only `boris.json` and regular files under `content/` or
  `themes/` are listed and editable.
- **Create / rename / delete** — rename refuses to clobber an existing file;
  delete requires confirmation and applies immediately.
- **Conflict detection** — if a file changed, was deleted, or became read-only
  on disk after you opened it, the editor reports the problem and writes
  nothing. The conflict dialog keeps both your unsaved buffer and the current
  disk version visible and requires an explicit choice (keep editing, load the
  disk version, or replace it). The open file is probed while you work and
  when the window is focused, so an external edit, delete, or permission
  change does not wait for Save. Transient filesystem errors are skipped and
  retried.
- **Undo / redo** — session-local, keyboard-driven (`Ctrl/Cmd+Z`, `Ctrl/Cmd+
  Shift+Z`) and via the toolbar.
- **Recovery snapshots** — dirty buffers are snapshotted to the disposable OS
  user-cache state root on the first unsaved change, then periodically, and
  again when the tab hides. A later editor process labels them as *recovered
  unsaved work* and requires an explicit **Restore** or **Discard** action;
  recovery data never becomes repository truth unless you save it. If the
  editor host stops, the tab says to restart `boris-editor` and open the new
  launch URL.

There is no autosave: an explicit save is the only path from your buffer to
disk.

---

## Schema- and graph-aware completion

The source pane exposes an ARIA combobox whose completion categories are
explicit, so the editor does not need to parse frontmatter or Markdown. Every
suggestion comes from one of two published machine twins:

| Category | Source |
|---|---|
| Frontmatter key | `boris-frontmatter-1.schema.json`, embedded verbatim in the host at build time |
| Status value | `status.enum` from the frontmatter schema |
| Entity id | a successful Boris `.boris/completion.json` |
| Wiki link (`[[id]]`) | `.boris/completion.json` entities |
| Parent target | `completion.json` observed parent targets |
| Relation kind / target | `completion.json` relation kinds and entity targets |
| Layout slot (`{{slot}}`) | `completion.json` layout slots |

Schema suggestions are available before any IR artifact exists. Graph-backed
categories (entities, wiki-links, parents, relations, layout slots) explain
that **Build diagnostics** is required to create the completion index; after a
successful IR build the UI reloads `completion.json` without a restart.
Opening the project, saving, running a Boris command, rebuilding preview,
and refreshing completion name the wait and how long it took.

Insertion is explicit and undoable — there is no typing-time rewrite of your
source. The native textarea remains the editing surface.

- [[guides/building-pages|Building and writing pages]] — the frontmatter and
  wiki-link vocabulary these suggestions complete
- [[reference/frontmatter|Frontmatter reference]] — the closed key set

---

## Graph-aware navigation

The **Graph** pane is a read-only inspector of the last successful Boris
`graph.json`. It never edits the graph. After **Build diagnostics** the pane
shows the open page's parent, children, siblings, outgoing references and
includes, reverse-index backlinks, and any `relations` from
`completion.json`. Wiki-link tokens (`[[id]]`) in the current buffer are
listed and resolved against that same graph.

Named buttons open the target file. **Run impact on this page** fills the
impact field and runs the same `boris impact` command as the Problems pane.
`Ctrl+K` also jumps to an entity by id or title (`Go to guides/intro`).

If diagnostics have not been built yet, the pane says so instead of guessing.

- [[guides/building-pages|Building and writing pages]] — parent, children, and wiki links
- [[reference/relationships|Relationships]] — parent, children, and relations this pane displays

---

## Cooklang recipes

If `content/` is a `.cook`-only tree, the editor treats it as a Cooklang
project. Boris commands and preview run with `--cooklang`. Opening a recipe
shows a read-only **Recipe** pane from the compiler `recipe` facet:
ingredients, cookware, timers, and `recipeRef` links to other recipes. Print
uses that facet, not a second renderer.

Quantities stay the strings the author wrote. Boris can classify and scale
those strings; this editor does not run that operation
([issue 554](https://github.com/drawmeanelephant/boris/issues/554)).
Graph diagnostics that are not `ECOOKLANG` are marked **position
approximate** because Boris locates them on adapted Markdown.

- [[guides/building-pages|Building and writing pages]] — frontmatter and relations on recipe pages too

---

## Theme authoring

Open a file under `themes/` to see the closed layout-slot vocabulary next to
the buffer. **Build HTML** or **Validate project** now read Boris's HTML
`--report`, so layout errors (`ELAYOUT*`) and layout winners
(`ILAYOUTSELECTED`, including fallback) show in Problems.

Preview can be constrained to 375px, 768px, or 1440px. The accessibility
notes next to the frame are a review aid, not a certification.

- [[guides/themes-and-layouts|Themes and layouts]] — slots and assets the compiler owns

---

## Publication plan

The Publication pane lists existing `boris-publication-profile` files at the
project root (`boris.json`, and `standard-site.json` after `boris init`).
**Run publication plan** invokes `boris plan --profile PATH` and shows the
normalized declaration: input, declared target, public location, and HTML
targets. That command does not compile or publish.

Local evidence at `dist/_boris/proof/proof-pack.json` is shown when a previous
HTML build left a Proof Pack. That pack is target-local presentation. It is
not deployment verification. GitHub Pages deploy stays in the official
Actions workflow; Standard.site publish stays on the CLI. The editor does not
store secrets or run a deployer.

- [[guides/publishing|Publishing targets]] — profile, plan, and verified targets

---

## Compiler-backed commands and problems

The Problems pane runs a fixed allowlist of Boris invocations against saved
repository files. The UI cannot supply argv or a working directory, and all
controls are disabled while the active buffer is dirty (Boris reads files from
disk, not from your buffer).

| Button | Exact Boris invocation | Reads |
|---|---|---|
| Validate project | `boris validate --input content` | nothing |
| Build diagnostics | `boris build --input content --out .boris` | `build-report.json` |
| Build HTML | `boris build --input content --html-dir dist` | nothing yet (see below) |
| Check graph | `boris check --input content --format json --report .boris/editor-check.json` | Documentation Intelligence report |
| Run impact | `boris impact <id> --input content --format json --report .boris/editor-impact.json` | Documentation Intelligence report |
| Run publication plan | `boris plan --profile PATH` | stdout `boris-publication-plan` |

Boris exit codes stay distinct: **1** content/graph failure, **2**
usage/configuration failure, **3** I/O/system failure. The editor surfaces the
class plus the raw exit code.

Diagnostics are grouped by content-relative source, severity, and Boris code.
Each problem card offers:

- **Go to location** — navigates the source pane to the exact Boris-reported
  UTF-8 byte position (labeled *exact* when the compiler reported it, and
  *best-effort* when the editor adapted stderr).
- **Copy packet** — copies a bounded, metadata-only diagnostic packet with no
  source excerpt and no absolute project root.

Until the HTML-path machine-readable diagnostics contract lands, `Validate
project` and `Build HTML` use a bounded stderr adapter; a visible notice marks
those positions as best-effort. Analysis findings and impact endpoints are
displayed as Boris-owned facts — the editor never infers either.

- [[reference/diagnostics|Diagnostics reference]] — the error codes you will
  see here
- [[guides/overview|Content model and pipeline]] — what the graph checks

---

## Live preview

Preview serves the **committed `dist/` output**, byte-for-byte, from a second
ephemeral loopback origin that lives and dies with the editor process. An
explicit successful save requests the one fixed rebuild command:

```text
boris build --input content --incremental --html-dir dist
```

You can also trigger it with the **Rebuild preview** button. The UI reports
`idle`, `running`, `success`, `failed`, and `stale` distinctly. Boris's staged
output commit preserves the last valid `dist/` tree after a failed rebuild, so
the preview iframe advances only on success. Embedded preview content is
sandboxed; a named link opens the exact site origin in a new tab for full
behavior.

While the compiler-owned `boris serve` command is still in flight, this is an
honest fallback: failures show bounded Boris stderr and say so. There is no
HMR, CSS injection, watcher, or typing-triggered build.

---

## What the editor deliberately does not do

- No autosave, Git integration, or editor-owned graph.
- No LSP, frontmatter grammar, Markdown parser, or heading-fragment completion.
- No arbitrary commands: only the fixed allowlist above.
- No preview daemon or renderer: a fixed, visible rebuild command only.
- No deploy, deployment secrets, or hosting dashboard.
- This editor does not run recipe scaling
  ([issue 554](https://github.com/drawmeanelephant/boris/issues/554)).
- No layout diagnostics or autofix.

When a capability is missing, the editor says so instead of guessing — the
authoring hints, problem labels, and preview states are honest about their
source and confidence.

---

## Keyboard and voice names

Every core control is a named button, link, or standard field. The 14 #418
actions are exercised keyboard-only in CI. Create File offers `.md`,
`.textile`, or `.cook` from the same dialog; a Cooklang-only or Textile-only
tree prefills the matching extension.

Spoken macOS Voice Control and Windows Voice Access are not recorded as
passing in this tree. The accessibility-tree names are the Show-names analog.
Recipe scaling stays labeled unavailable.

If `graph.json`, `completion.json`, or a Proof Pack is corrupt or from an
unsupported schema, the editor stays open and tells you to Build diagnostics
or Build HTML. It does not rewrite the artifact. The Project pane also names
the IR versions this editor adapter accepts.

A single author file may be at most 8 MiB. A project may list at most 50,000
author-owned files. Those bounds are spoken in the status line. If a Boris
command is killed or times out, the same named button retries it.

The Project pane paints at most 200 file buttons. **Filter project files**
narrows the list by path. The command palette shows at most 50 files and
graph entities until you type a filter; a filter can surface up to 200
matches. The open file stays in the tree even when it is outside the
visible window.

Save is one in-flight write at a time. A second Save or Ctrl+S during that
write is ignored so the fingerprint cannot race. If a crash-recovery snapshot
is unreadable, valid snapshots still appear and the status line says how many
were ignored.

<Details summary="The editor is not a second compiler">

It does not own frontmatter grammar, Markdown, the graph, or publication.
Boris and Oliver stay the authorities. Saving is explicit. There is no
autosave.

</Details>

---

## Next steps

- [[guides|User guides]] — back to the guide index
- [[guides/oliver-markdown|Markdown syntax]] — what the source pane accepts
- [[guides/publishing|Publishing targets]] — what a successful HTML build is for
- [[reference/commands|CLI reference]] — every compiler command the editor wraps
