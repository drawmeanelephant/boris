---
title: "`tools/source-rag/main.zig` overview"
id: docs/tools/source-rag/main
status: draft
tags: [boris, zig, tools, source-rag, main]
---

# `tools/source-rag/main.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/tools/source-rag/main/surface-and-execution|Surface and execution]]
* [[docs/tools/source-rag/main/evidence-and-cases|Evidence and cases]]
* [[docs/tools/source-rag/main/review-state|Review state]]

## Executive summary

`tools/source-rag/main.zig` implements a standalone source-code corpus exporter intended for LLM notebooks, review workflows, chat uploads, and similar repository-inspection tasks. It discovers selected text files beneath a caller-selected repository root, wraps each accepted source file in a Markdown retrieval document, builds catalogs and manifests, optionally combines those documents into size-targeted bundles, and publishes the resulting generated corpus beneath a caller-selected output path. The source explicitly distinguishes this corpus from Boris product content RAG and from the ordinary Boris compiler path (`main.zig:1-11`, `294-339`, `1442-1621`).

This file is not merely a process launcher. It contains the CLI parser, input profiles, file discovery, filtering, path classification, Markdown rendering, JSON and JSONL serialization, bundle partitioning, optional per-tool pack partitioning, upload planning, staged publication, rollback logic, process entry point, fixtures, and 23 inline tests. Its only Zig import is `std`; no Boris compiler module or other repository module is imported (`main.zig:13-14`). Based on the target file alone, the implementation is substantially self-contained.

The default scan considers selected root files and the `src`, `docs`, `content`, `layouts`, `scripts`, `tools`, `test`, `fixtures`, and `SUPPORT` trees when present. Profiles restrict that selection to `core`, `docs`, or `tools`. Files are included through an extension allowlist, with selected extensionless license names, and are excluded through fixed cache, generated-output, build, and vendor rules. Accepted source paths are sorted bytewise and deduplicated before reading (`main.zig:110-199`, `483-576`).

For each accepted file, the tool reads the whole file into memory, rejects files exceeding `max_bytes`, rejects files containing a NUL byte in the first 8 KiB, and retains the accepted body for bundle construction. It can emit one Markdown document per source path under `files/`, combined `source`, `docs`, and `content` bundles, human indexes and upload instructions, a JSONL catalog, and several JSON manifests. With `--pack-by=tool`, it instead creates self-contained pack trees under `packs/`, plus a root router and pack manifest (`main.zig:789-1410`, `1442-1748`, `1771-2132`).

The implementation contains strong local mechanisms for repeatable output: sorted discovery, sorted catalog records, fixed JSON field order, deterministic bundle grouping, contiguous whole-file partitioning, sorted pack names, no generated timestamps, and no generated random identifiers. Inline tests compare repeated runs byte for byte for representative flat and bundles-only fixtures. Those tests also cover stale managed-file cleanup and preservation of an earlier successful corpus when a failure is injected during staging. This dossier could not execute those tests because no Zig compiler was available in the analysis environment, so their current passing status is unverified.

Publication is staged under a sibling path derived from `--out`. Managed artifacts from the previous corpus are moved to a recovery directory, staged artifacts are moved into place, and restoration is attempted if installation fails. Unrelated siblings in the output directory are deliberately preserved. This is stronger than deleting and recreating the output root, but it is not proven to be a universally atomic transaction. A rollback failure returns `SourceRagPublishRestoreFailed`, cleanup failures may leave recovery material, and publication-failure branches are not directly exercised by the visible tests (`main.zig:600-778`).

The file does not establish the root build declarations, standalone `build.zig` contents, target or optimization propagation, root convenience-step wiring, repository ignore rules, release status, or whether another repository file imports this file. Source-authored usage text names `zig build source-rag` and `zig-out/bin/boris-source-rag`, but the build files needed to verify those commands were unavailable. The implementation also does not compute source digests, evaluate documentation correctness, semantically interpret Zig, invoke an LLM, upload artifacts, access the network, invoke subprocesses, or prove that generated corpus files are normative documentation.

## Classification

| Property                      | Assessment                                                                                                                                                      |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Primary classification        | Standalone developer-tool implementation and executable entry point                                                                                             |
| Conceptual domain             | Mechanical repository-source discovery, packaging, indexing, bundling, and upload planning                                                                      |
| Tool family                   | Source-RAG corpus exporter                                                                                                                                      |
| Build root                    | Unknown; no `build.zig` or `build.zig.zon` was available                                                                                                        |
| Executable or module name     | Source-authored name: `boris-source-rag`; exact build declaration unverified                                                                                    |
| Product runtime dependency    | No Boris product module is imported; reverse linkage from product build or source is unknown                                                                    |
| Root build integration        | Source usage claims a `source-rag` build step; actual root build wiring is unavailable                                                                          |
| Expected execution commands   | Source-documented: `zig build source-rag`, `zig build source-rag -- [options]`, and `zig-out/bin/boris-source-rag [options]`                                    |
| Input authority               | Current filesystem contents beneath `--root`, filtered by hard-coded profiles and inclusion rules                                                               |
| Output ownership              | Fixed managed files, generated bundle-name patterns, and the managed `files/` or `packs/` trees beneath `--out`; sibling stage and recovery paths are also used |
| Network or subprocess use     | None in the target implementation; only filesystem, allocation, formatting, process-argument, and diagnostic APIs are used                                      |
| Main collaborators            | Zig standard library, caller-selected repository tree, generated Markdown/JSON consumers                                                                        |
| Documentation depth warranted | High; the file contains the complete visible implementation, publication logic, formats, and substantial inline tests                                           |

## Role in the Boris architecture

The target file presents source-RAG as an auxiliary repository tool, not as a component of Boris page compilation. Its module-level comments, usage text, generated index, and upload guide all describe a codebase pack that is separate from Boris product content RAG (`main.zig:1-11`, `294-339`, `1442-1748`). This distinction is also reflected structurally: the file imports only `std` and does not import a Boris parser, resolver, renderer, IR type, frontmatter type, content-RAG component, or Context Bundle component.

The file defines `pub fn main(init: std.process.Init) u8`, so it is directly capable of serving as an executable root. It also exposes `exportCorpus`, `parseOptions`, several enums, and selected helper functions, allowing tests or another module to invoke parts of the implementation. No evidence was available showing whether another tool actually imports it.

The exact build relationship remains partly unknown:

* **Linked into production:** not demonstrated. The target has no product imports, but reverse imports and root executable wiring were unavailable.
* **Compiled as a separate executable:** strongly suggested by the dedicated `main`, executable name, help text, and direct-binary command. The build declaration itself was unavailable.
* **Imported by another tool:** unknown.
* **Used only as a test root:** no. It contains a real process entry point and full export path in addition to tests.
* **Exposed through convenience build steps:** source-authored usage says `zig build source-rag`; the actual root step and dependencies are unverified.
* **Standalone build file:** unknown because `tools/source-rag/build.zig` and `build.zig.zon` were unavailable.

The tool reads Boris source, documentation, content, layouts, scripts, tests, fixtures, and selected root files as opaque repository evidence. Reading those files does not create an imported runtime dependency on the Boris compiler. Accepted file bodies are classified by path and language extension, but are not parsed according to Boris semantics.

Generated `source-rag/` output is a disposable knowledge pack. `catalog.jsonl`, manifests, per-file documents, and bundles describe what the exporter observed during one run. They are not authoritative replacements for current source files, contracts, tracked documentation, product IR, or compiler behavior.

The implementation has no visible integration with product content RAG, Context Bundles, documentation-observatory reporting, or migration tools. Those areas may appear among scanned inputs, but the exporter treats them as files to package. It does not execute them, validate them, or merge their behavior into its own.

LLM and review systems are consumers of the generated output, not collaborators in generation. The exporter writes local files only. It contains no upload client, model invocation, retrieval engine, embedding generator, or network transport.

## Tool boundary and non-goals

### Implemented boundary

The tool may inspect:

* selected root-level repository files;
* selected candidate directory trees;
* regular files whose names pass the inclusion rules;
* file sizes and source bytes;
* output and recovery directories required for publication.

It may write:

* generated corpus artifacts beneath `--out`;
* a sibling staging directory named `<out>.boris-source-rag-stage`;
* a sibling recovery directory named `<out>.boris-source-rag-prev`;
* parent directories required to create those paths.

It intentionally manages only named exporter artifacts. The output root itself is not deleted. Unknown sibling files under the output root are preserved by publication, as directly asserted with `user-note.txt` in multiple tests (`main.zig:600-778`, `2363-2548`, `3085-3282`).

The implementation does not write to discovered source paths. It does not open source files for mutation, change compiler behavior, rewrite frontmatter, emit product IR, migrate content, or alter tracked documentation. This boundary depends partly on caller discipline because `--out` accepts an arbitrary nonempty path. A caller can point `--out` into a tracked tree, and the implementation does not consult version-control metadata before writing.

### Semantic non-goals

The exporter performs mechanical selection and packaging. It does not:

* parse Zig syntax;
* resolve imports;
* evaluate documentation correctness;
* compare documentation with implementation;
* infer semantic relationships;
* determine whether a changed file invalidates documentation;
* produce embeddings;
* invoke an LLM;
* call an upload API;
* access the network;
* invoke subprocesses;
* act as a migration engine;
* become part of the ordinary `boris` process through any import visible here.

The generated upload guide includes suggested downstream prompts, but those strings are documentation emitted into the corpus. They do not execute a model (`main.zig:1623-1748`).

### Documented intention versus enforcement

The source describes paths as repository-relative and the output as a source-code knowledge dump. Repository-relative source paths are structurally produced by walking from an opened root directory. However, `--root` and `--out` themselves may be absolute, relative, symlinked, or contain `.` and `..`; the implementation does not canonicalize them.

The source calls the managed publication “atomic” in comments. The implementation does stage a complete managed corpus and uses rename-based replacement with rollback. It does not establish universal atomicity across all filesystems and failure combinations. This dossier therefore describes it as staged managed-artifact replacement, not as an unconditional atomic guarantee.

## Build and invocation model

The file is a Zig executable-capable root because it defines `pub fn main(init: std.process.Init) u8` (`main.zig:2138-2194`). The same file contains inline `test` declarations, allowing it to act as a test root when selected by a build or direct test command.

Only `std` is imported. There are no named build options, generated configuration imports, or repository modules in the target source. Runtime options are parsed from process arguments rather than injected by the build.

The following build properties remain unknown because the relevant files were unavailable:

* executable declaration and exact artifact name;
* root-module declaration;
* standalone `tools/source-rag/build.zig` contents;
* standalone package dependencies;
* root `build.zig` step definitions;
* root or standalone test steps;
* target and optimization propagation;
* install behavior;
* whether root and standalone builds produce the same artifact;
* whether any build-generated files are prerequisites.

The implementation assumes the current working directory when opening both `--root` and `--out`. Their defaults are `.` and `source-rag`, respectively. Relative paths are interpreted by `Io.Dir.cwd()` (`main.zig:30-64`, `1896-1983`).

| Command                                  | Purpose                                           | Inputs                                                      | Outputs                                     | Notes                                                                          |
| ---------------------------------------- | ------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------- | ------------------------------------------------------------------------------ |
| `boris-source-rag [options]`             | Run the executable                                | Process arguments, current working directory, selected root | Generated corpus or usage/error diagnostics | Present in runtime usage text; executable installation path is not established |
| `zig build source-rag`                   | Build or run the root convenience step            | Root build graph                                            | Unknown from available evidence             | Printed by source comments and help text; root step unavailable                |
| `zig build source-rag -- [options]`      | Invoke the source-RAG step with runtime arguments | Root build graph and CLI options                            | Generated corpus                            | Source-documented; exact build step behavior unverified                        |
| `zig-out/bin/boris-source-rag [options]` | Run an installed executable directly              | Installed artifact and CLI options                          | Generated corpus                            | Source-documented; install declaration unverified                              |
| `zig-out/bin/boris-source-rag --help`    | Print usage and exit successfully                 | Installed artifact                                          | Usage text on diagnostic output             | Source-documented and structurally handled by `main`                           |

No direct `zig test` command is included because the build and Zig-version context needed to support an exact command was unavailable.
