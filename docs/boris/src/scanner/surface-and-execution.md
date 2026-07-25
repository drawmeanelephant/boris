---
title: "`src/scanner.zig` surface and execution"
id: docs/boris/src/scanner/surface-and-execution
parent: docs/boris/src/scanner
status: draft
tags: [boris, zig, source-reference, surface, scanner]
---

# `src/scanner.zig` surface and execution

## Behavioral contracts

All contracts listed here are normative per `docs/contracts/scanner.md`. Claims about enforcement are supported by direct code inspection unless marked otherwise.

### Extension policy
Only lowercase `.md`, `.mdx`, or (in explicit Textile mode) `.textile` are accepted. Mixed-case variants (`.MD`, `.MDX`, `.Md`, `.TEXTILE`) are silently ignored. A recognized page extension from the non-selected family is a hard error (`InputFormatMismatch`), not a silent ignore. This is structurally enforced by `identity.isPageFile` (silent filter) followed by `identity.contentKind` (classifies) and then `InputFormat.accepts` (rejects cross-family). 

### Symlink policy
The walker emits symlink entries with `entry.kind == .sym_link`; the scanner checks this before any `stat` and returns `error.SymlinkRejected` immediately without reading or entering the target. For file entries, a secondary `statFile(..., .{ .follow_symlinks = false })` call confirms the entry is not a disguised symlink; if it is, `SymlinkRejected` is returned. This is defense-in-depth against walkers that may misreport entry kind. 

### Cycle detection
Before entering any real directory, the scanner calls `entry.dir.statFile` to obtain the inode, checks the inode against the `visited_dirs` list with `identitySeen` (linear scan), and appends it only if unseen. A repeated inode returns `error.SymlinkCycle`. The `walker.enter` call also catches `error.SymLinkLoop` from the OS layer and maps it to `SymlinkCycle`. This provides two independent cycle-detection gates. 

### Reserved directories
The content-root `includes/` directory is skipped by comparing `entry.path` (the full content-root-relative walk path) to the literal string `"includes"`. Only the top-level reservation is checked by the directory-skip guard; however, a defense-in-depth check in the file-registration path also rejects entries whose path equals `"includes"` or starts with `"includes/"`, preventing fragments from being registered even if the walker were somehow entered into that directory. Nested `guides/includes/` trees are explicitly confirmed to not be reserved. 

Directories whose basename ends with `.assets` are skipped entirely by the walker (`continue` before `walker.enter`), so no content under asset trees is ever seen by the scanner. 

### Sort contract
`page_mod.sortPages` is called once, at the very end of `scanDirFormat`, before the function returns. The sort key is `entity_id` ascending (bytewise UTF-8), with `source_path` as a stable tie-breaker for duplicate-id pairs. This is directly verified by the sort-stability and duplicate-preservation tests. 

### Duplicate ids
When two source files produce the same `entity_id` (for example, `same.md` and `same.mdx`), both are appended to the list without error. Discovery does not mask duplicates. This is structurally enforced by the absence of any deduplication logic in `registerPage` or `scanDirFormat`. The duplicate-id test directly demonstrates both entries survive with the correct sort order. 

### Allocation and path lifetime
`entry.path` is documented as invalidated on the next `walker.next()` call. `registerPage` immediately copies it via `identity.canonicalize(retain, walk_path)`, allocating on the retain arena. All subsequent strings (`entity_id`, `output_path`) are also allocated on `retain`. The walker's temporary `visited_dirs` list uses `list_gpa` and is freed by `defer` before the function returns. These properties are structurally visible in the code; they are not tested in isolation by the scanner's own test suite. 

***

## Allocation ownership map

| Allocator | Data owned | Freed by |
| :-- | :-- | :-- |
| `list_gpa` | `visited_dirs` ArrayList spine | `defer visited_dirs.deinit(list_gpa)` at end of `scanDirFormat` |
| `list_gpa` | `walker` internal buffers | `defer walker.deinit()` at end of `scanDirFormat` |
| `list_gpa` | `out.pages` ArrayList spine | Caller calls `out.deinit()` / `list.deinit()` |
| `retain` | All string fields on each `Page` (`source_path`, `entity_id`, `output_path`) | Caller owns retain arena; typically `arena.deinit()` after use |

The scanner itself never frees retain-owned strings. Intermediate strings produced inside `registerPage` (e.g., the `canon` slice from `identity.canonicalize`) are freed immediately via `defer allocator.free(canon)` before returning.

***

## Relationship to normative contract

`docs/contracts/scanner.md` is the normative specification. Every policy listed there — extension policy, symlink policy, `includes/` reservation, `.assets` skip, sort key, duplicate handling, error table — has a corresponding structural enforcement point in `src/scanner.zig`. The tests directly demonstrate most policy cases. The gap between contract and test coverage is modest: the `.assets` skip, the stat-based symlink second layer, and the `SymlinkCycle` live-fixture case are the main untested-but-structurally-present items.

***
