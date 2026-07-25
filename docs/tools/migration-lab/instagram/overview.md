---
title: "`tools/migration-lab/instagram.zig` overview"
id: docs/tools/migration-lab/instagram
status: draft
tags: [boris, zig, tools, migration-lab, instagram]
---

# `tools/migration-lab/instagram.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/tools/migration-lab/instagram/surface-and-execution|Surface and execution]]
* [[docs/tools/migration-lab/instagram/evidence-and-cases|Evidence and cases]]
* [[docs/tools/migration-lab/instagram/review-state|Review state]]

## Executive summary

`tools/migration-lab/instagram.zig` is the Instagram migration module inside the `boris-migration-lab` standalone developer tool. It is not an entry point; it is one of thirteen mode modules imported by `tools/migration-lab/main.zig` and dispatched to when the user selects `--mode instagram` (aliases: `ig`, `takeout`) or supplies `--dump`. The file implements the full Instagram Takeout conversion pipeline in a single Zig source: reading an unpacked Meta "Download your information" export directory, parsing JSON and HTML post records, assembling `IgRecord` structs, emitting deterministic Boris-ready Markdown pages under `--out/content/`, copying source media bytes unchanged into `--out/theme/assets/media/`, generating theme scaffold files (`layouts/main.html`, `footer.html`, `assets/css/site.css`), and writing `report.json`, `REPORT.md`, and `mediamanifest.json` machine and human reports.

The file's `pub fn run(io, gpa, opts)` is the sole public entry point and is called exclusively from `main.zig`. Everything else—model types, JSON parsing helpers, HTML post parsing, caption encoding repair, media-URI safety checks, entity-ID derivation, report serialization, and filesystem helpers—is declared in the same file. There are no sub-module imports beyond `@import("std")` and `std.Io`. The file is self-contained at the module level; it neither imports sibling migration modules nor exposes symbols for consumption by other tools.

The tool's purpose is a one-shot, author-assisted migration preparation workflow: the author runs the lab against their unpacked export, reviews the generated Markdown and reports, then feeds the output content tree to the `boris` product compiler. The lab itself never invokes Boris, never touches the product compiler pipeline, never writes back into the source export, and explicitly carries no network access, ZIP extraction, scraping, OCR, or API calls. The separation between the migration laboratory and the Boris product binary is architectural: `tools/migration-lab/` has its own `build.zig`, its own `build.zig.zon`, and its own test gate; the root `build.zig` deliberately does not include it.

Format identity is declared inline: `pub const format_id = "boris-instagram-migration-lab"` and `pub const schema_version: u32 = 1`. The current tool version is declared as `pub const tool_version = "0.1.0"`. These constants are embedded in all machine-readable output, providing a stable header for downstream consumers.

The fixture `fixtures/mini-instagram/` is a synthetic Takeout-style tree covering simple photos, carousels, videos, missing media, duplicate basenames across different directories, Unicode captions, empty media records, caption-less media, Meta-escaped Latin-1/UTF-8 caption repair, reels, stories, and unknown `othercontent`. The fixture is exercised by the tool's own declared test. A separate `fixtures/hostile-instagram/` fixture covers adversarial path traversal cases. The test coverage directly demonstrated by in-module tests is present but limited to fixture-based integration; fine-grained unit tests for helpers such as `isSafeMediaUri`, `extractDurableId`, `repairMetaEscapedUtf8`, and `fallbackHashId` are present as top-level functions but their direct test declarations were not confirmed separately from the fixture integration run.

What the file and its tests do **not** prove: byte-for-byte cross-platform identity of output on Windows versus POSIX; atomicity or rollback of partial output on I/O failure mid-run; absence of memory leaks (the `main.zig` comment notes Instagram tests "currently leak under the testing allocator" and excludes them from `refAllDecls`); safe behavior against every possible malicious archive shape beyond the documented path-traversal and `.` and `..` and backslash and drive-prefix checks.

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Developer-tool implementation module |
| Conceptual domain | Migration laboratory — Instagram Takeout conversion |
| Tool family | `boris-migration-lab` (standalone, separate from `boris` product) |
| Build root | `tools/migration-lab/build.zig` |
| Executable or module name | Compiled into `zig-out/bin/boris-migration-lab`; this file is a module, not the root |
| Product runtime dependency | No — not linked into the `boris` product binary |
| Root build integration | None — root `build.zig` does not include `tools/migration-lab/` |
| Expected execution commands | `zig build run -- --mode instagram --dump <dir> --out <dir>` (from `tools/migration-lab/`) |
| Input authority | Unpacked Instagram data-download root (never modified) |
| Output ownership | Writes only under the explicitly configured `--out` directory |
| Network or subprocess use | None — structurally absent; no system calls to network or shell |
| Main collaborators | `main.zig` (caller/dispatcher), `fixtures/mini-instagram/`, `fixtures/hostile-instagram/` |
| Documentation depth warranted | High — conversion logic, safety checks, encoding repair, and report schema are non-trivial |


***

## Role in the Boris architecture

`instagram.zig` is a migration-laboratory module, not a product compiler module. The `boris` product binary (`zig-out/bin/boris`) is built from the repository root `build.zig` and knows nothing about `tools/migration-lab/`. The lab binary (`zig-out/bin/boris-migration-lab`) is built from `tools/migration-lab/build.zig` alone. These are two separate executables with separate build graphs, separate dependency manifests (`build.zig.zon`), and separate test gates.

`instagram.zig` is **not** linked into production. It is **not** imported by any source-RAG tool, Context Bundle tool, or any other tool outside `tools/migration-lab/`. It is imported only by `tools/migration-lab/main.zig` as `const instagram = @import("instagram.zig")` and dispatched to via `instagram.run(io, gpa, .{ .dumpdir = dump, .outdir = opts.outdir, .quiet = opts.quiet })`.

Its outputs are entirely disconnected from normal Boris HTML publication. The generated `content/` tree under `--out` is intended as a starting point for human author review; it requires the author to inspect and then optionally pass it to the `boris` product compiler as a separate, subsequent manual step. The lab's `report.json` and `mediamanifest.json` outputs are migration-audit artifacts, not Boris IR, not Context Bundles, not source-RAG packs, and not documentation observatory records.

***

## Tool boundary and non-goals

The boundary between this module and the Boris product is fully implemented, not merely documented:

- **Allowed to inspect:** the `--dump` directory and any file path referenced by a media URI that passes `isSafeMediaUri`, provided that URI does not contain `..`, `/` as first character, `\`, or a Windows drive prefix.
- **Allowed to write:** only files under the `--out` directory (enforced in `main.zig` by a string-equality check refusing `--dump == --out`, and structurally by all filesystem writes being rooted at the opened output directory handle).
- **Does not modify tracked source files:** structurally enforced — the dump is opened read-only; no write call targets the dump directory handle.
- **Does not change compiler behavior:** the lab is not in the Boris compiler's import graph.
- **Does not change product frontmatter or IR:** it generates its own Boris-compatible closed frontmatter (`id`, `title`, `parent`, `status`, `tags`) as text, but the `boris` compiler is not involved in this generation.
- **Does not perform semantic interpretation:** the lab converts structure and preserves bytes; it does not evaluate the correctness or quality of content.
- **Does not evaluate documentation correctness:** explicitly a non-goal.
- **Does not invoke an LLM:** no LLM integration, confirmed by absence of any API call or network socket code.
- **Does not upload data:** no network access.
- **Does not access the network:** structurally absent in the implementation.
- **Does not act as a migration tool in the product's ordinary execution path:** explicitly not part of the Boris runtime. `tools/` is a separate subtree.

***

## Build and invocation model

`instagram.zig` has no standalone build file of its own. It participates in the `tools/migration-lab/build.zig` build as a module imported by `main.zig`. The root `build.zig` does not reference `tools/migration-lab/` at all.

The standalone tool executable is named `boris-migration-lab`. From within `tools/migration-lab/`:

```
zig build                        # build only
zig build run -- --mode instagram --dump ./fixtures/mini-instagram --out ../ig-report
zig build test                   # run all lab tests including Instagram fixture tests
```

From the repository root (using the `--build-file` override):

```
zig build --build-file tools/migration-lab/build.zig
zig build --build-file tools/migration-lab/build.zig test
zig build --build-file tools/migration-lab/build.zig run -- \
  --mode instagram --dump tools/migration-lab/fixtures/mini-instagram \
  --out /tmp/ig-mig-report
```

The `zig build run` path and the direct `./zig-out/bin/boris-migration-lab` invocation produce the same executable artifact. No generated artifacts are prerequisites for the build.

### Command table

| Command | Purpose | Inputs | Outputs | Notes |
| :-- | :-- | :-- | :-- | :-- |
| `zig build run -- --mode instagram --dump <dir> --out <dir>` | Full Instagram migration | Unpacked Meta export directory | `content/`, `theme/`, `report.json`, `REPORT.md`, `mediamanifest.json` under `--out` | `--dump` implies `--mode instagram` automatically |
| `zig build test` | Run all lab tests including Instagram fixture integration | `fixtures/mini-instagram/`, `fixtures/hostile-instagram/` | Pass/fail; test output directories under `fixtures/` | Instagram tests noted as leaking under testing allocator; excluded from `refAllDecls` in `main.zig` |
| `./zig-out/bin/boris-migration-lab --dump <dir> --out <dir>` | Direct invocation after build | Same as above | Same as above | Equivalent to `zig build run --` form |


***
