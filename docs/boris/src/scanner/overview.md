---
title: "`src/scanner.zig` overview"
id: docs/boris/src/scanner
status: draft
tags: [boris, zig, source-reference, scanner]
---

# `src/scanner.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/scanner/surface-and-execution|Surface and execution]]
* [[docs/boris/src/scanner/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/scanner/review-state|Review state]]

## Executive summary

`src/scanner.zig` is the deterministic recursive content-discovery module for Boris milestone 4. Its sole public responsibility is to walk a content root directory, identify page files that belong to the explicitly selected input format family, derive canonical identity records for each, and deliver a sorted flat list of `Page` values to the caller before any downstream stage (frontmatter parse, graph resolution, HTML render, Apex) has been invoked. It has no frontmatter awareness, no graph logic, no rendering, and no concurrency. 

The file implements three public entry points — `scan`, `scanDir`, and `scanDirFormat` — that converge on a private `scanDirFormat` implementation driving a `Io.Dir.SelectiveWalker`. Within the walk loop, the code enforces a strict policy hierarchy: symlinks are rejected unconditionally; directories are entered only once per filesystem inode (cycle detection via a linear `FsIdentity` list); the content-root `includes/` subtree and any directory whose name ends with `.assets` are skipped; and every file entry must pass a case-sensitive page-extension gate and an input-format family check before being registered. A secondary `stat` call with `follow_symlinks = false` provides defense-in-depth against walker entries that superficially appear to be regular files but are actually symlinks. 

The file protects the Boris content model against several categories of subtle filesystem hazard: symlink cycles that would otherwise loop the walker indefinitely; cross-family contamination where a Markdown-mode scan would silently accept `.textile` pages (or vice versa); path traversal accidents that could escape the output root via `../` segments derived from filenames; and non-determinism arising from filesystem enumeration order. Duplicate entity ids — which can arise legitimately from a `.md`/`.mdx` pair with the same stem — are intentionally preserved rather than masked, so a later graph validation stage can emit a precise `EDUPLICATEID` diagnostic with both source paths visible. 

Allocation ownership is explicit and two-tier: a `list_gpa` general-purpose allocator owns the `ArrayList` spine and temporary walk state (the `visited_dirs` list is freed by `defer` before the function returns), while a long-lived `retain` allocator owns every string field on every `Page`. The `entry.path` slice from the walker is invalidated on the next `next()` call, so `registerPage` copies it to the retain arena via `identity.canonicalize` before any other operation. No arenas are created inside the scanner itself; callers supply both allocators, separating their lifetimes completely. 

The file carries its own unit and integration tests in a `// Tests` section at the bottom. These tests run as a dedicated `scanner_tests` build step with the repository root as the working directory, giving them access to `fixtures/content/valid` and `fixtures/content/invalid` as stable reference fixtures. Eleven tests cover: recursive discovery against the live fixture tree; sort determinism independent of filesystem creation order; `includes/` skip (root-only); extension case-sensitivity; Textile-mode isolation; cross-family hard-error; missing root; directory symlink rejection; page-file symlink rejection; and duplicate-id preservation. Platform-conditional guards (`if (builtin.os.tag == .windows) return;`) protect symlink tests on Windows and on hosts that deny symlink creation. 

What the file does not prove: it does not test scanner behavior under allocation failure (OOM injection); it does not exercise very deep directory trees; it does not demonstrate behavior when the walker raises `error.SymLinkLoop` on a platform that returns it rather than a stat-based cycle; it does not cover the `scanDir` (format-defaulting) overload separately; and it does not test `SymlinkCycle` in a live filesystem scenario — that case is handled structurally by the inode check but has no corresponding `expectError` test. 

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production library module with embedded tests |
| Conceptual domain | Content discovery / filesystem walk / identity derivation |
| Build or test root | `src/scanner.zig` — `scanner_mod` in `build.zig` |
| Production runtime dependency | Yes — imported by `src/pipeline.zig` and any path that calls `scan` or `scanDir` |
| Expected execution command | `zig build test` (runs `run_scanner_tests`); or `zig test src/scanner.zig` from the repo root |
| Main collaborators | `src/identity.zig`, `src/page.zig`, `std.Io`, `std.Io.Dir.SelectiveWalker` |
| Documentation depth warranted | High — normative behavior, explicit contract doc, multiple policy categories |

***

## Role in the Boris architecture

`src/scanner.zig` is the first active stage of the Boris compilation pipeline. It sits immediately after CLI option parsing and before `parser.zig`, `graph.zig`, and anything involving Apex or HTML rendering. In the milestone-4 pipeline it is the only module that touches the filesystem during content discovery; all later stages operate on the `PageList` or `PageDb` data structures that the scanner populates. 

The scanner is linked into the product binary (`src/main.zig`) via `root_mod`, which imports `scanner.zig` transitively through `pipeline.zig`. It is not test-only code. The scanner module is also compiled as a separate `scanner_mod` build target in `build.zig` for its standalone test step, but this produces only a test binary — the same source participates in both the product link and the test link. 

The scanner has no dependency on `src/apex.zig`, the hostile C double, the real ApexMarkdown engine, or any Apex build options. Its `build_options` are not wired into the `scanner_mod` build step. The scanner is therefore unaffected by the `hostile_apex` flag. 

`src/identity.zig` is the scanner's core collaborator: `identity.canonicalize` normalizes raw walker paths; `identity.canonicalEntityId` derives the graph key; `identity.safeOutputRelativePath` builds the output-relative HTML path; `identity.isPageFile` and `identity.contentKind` implement the case-sensitive extension gate; and `identity.InputFormat.accepts` enforces input-family isolation. The scanner delegates all path logic to `identity.zig` and does none of it ad-hoc. 

`src/page.zig` provides the `Page` struct, `PageList` container, and `sortPages` function. The scanner calls `page_mod.sortPages(out.pages.items)` as the final step, after which the list is handed to the caller in a deterministic, sorted state. The scanner does not own the `PageList`; it only appends to one supplied by the caller. 

***
