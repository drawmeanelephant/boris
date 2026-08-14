---
title: Boris Editor
parent: guides/overview
status: published
tags: [guides, editor, authoring, completion, preview]
---

# Boris Editor: compiler-backed authoring

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

- `[[cli-and-modes|CLI and modes]]` — the compiler surface the editor drives
- `[[themes-and-layouts|Themes and layouts]]` — what `Build HTML` produces

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
  disk version, or replace it).
- **Undo / redo** — session-local, keyboard-driven (`Ctrl/Cmd+Z`, `Ctrl/Cmd+
  Shift+Z`) and via the toolbar.
- **Recovery snapshots** — dirty buffers are snapshotted to the disposable OS
  user-cache state root. A later editor process labels them as *recovered
  unsaved work* and requires an explicit **Restore** or **Discard** action;
  recovery data never becomes repository truth unless you save it.

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

Insertion is explicit and undoable — there is no typing-time rewrite of your
source. The native textarea remains the editing surface.

- `[[building-pages|Building and writing pages]]` — the frontmatter and
  wiki-link vocabulary these suggestions complete
- `[[reference/frontmatter|Frontmatter reference]]` — the closed key set

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

- `[[reference/diagnostics|Diagnostics reference]]` — the error codes you will
  see here
- `[[overview|Content model and pipeline]]` — what the graph checks

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
- No layout diagnostics or autofix.

When a capability is missing, the editor says so instead of guessing — the
authoring hints, problem labels, and preview states are honest about their
source and confidence.

---

## Next steps

- `[[guides|User guides]]` — back to the guide index
- `[[oliver-markdown|Markdown syntax]]` — what the source pane accepts
- `[[reference/commands|CLI reference]]` — every compiler command the editor wraps
