---
title: "`src/scanner.zig` evidence and cases"
id: docs/boris/src/scanner/evidence-and-cases
parent: docs/boris/src/scanner
status: draft
tags: [boris, zig, source-reference, evidence, scanner]
---

# `src/scanner.zig` evidence and cases

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| --- | --- | --- | --- | --- | --- |
| `scan` | `pub fn` | Open `options.content_root` relative to CWD and delegate to `scanDirFormat` | `Io`, `Options`, `*PageList` | Sorted `PageList` or `ScanError` | Top-level public entry point |
| `scanDir` | `pub fn` | Scan an already-open dir handle, defaulting to Markdown format | `Io`, `Io.Dir`, `*PageList` | Sorted `PageList` or `ScanError` | Markdown-default convenience wrapper |
| `scanDirFormat` | `pub fn` | Core walk loop; enforces all scanner policies | `Io`, `Io.Dir`, `InputFormat`, `*PageList` | Sorted `PageList` or `ScanError` | All contracts |
| `registerPage` | `fn` (private) | Canonicalize path, derive entity id and output path, append `Page` | retain allocator, `*PageList`, raw walk path | Page appended to `out` or `ScanError` | Path canonicalization, identity derivation, output-path safety |
| `FsIdentity` | `const` (private) | Inode-based filesystem identity for cycle detection | `Io.File.Stat` | Comparable value | Cycle detection |
| `identitySeen` | `fn` (private) | Linear scan of `visited_dirs` | `[]const FsIdentity`, `FsIdentity` | `bool` | Cycle detection |
| `tmpContentRoot` | `fn` (test helper) | Create a `content/` subdirectory under a `TmpDir` and return its path | `gpa`, `io`, `*TmpDir` | Allocated path string | Test setup only |
| `"scan: recursive fixtures/content/valid"` | `test` | Verifies 4 pages discovered, sorted by entity_id, correct source/output/kind fields, no absolute or backslash paths | Live `fixtures/content/valid` fixture | Exactly 4 entries with asserted field values | Discovery, sort, field correctness, path-format invariants |
| `"scan: recursive fixtures/content discovers nested invalid suites"` | `test` | Verifies all-fixtures walk yields ≥14 pages in sorted order | Live `fixtures/content` tree | `list.len() >= 14`, pairwise sort assertion | Sort determinism over a larger real corpus |
| `"scan: stable sorted order independent of creation order"` | `test` | Creates 5 files in reverse entity-id order, verifies sort output is forward order | `TmpDir` with 5 files created reverse-alphabetically | Exact entity_id order: `a-first`, `m-mid`, `nested/a-nested`, `nested/z-nested`, `z-last` | Sort independence from filesystem creation order |
| `"scan: skips content-root includes/ fragment library"` | `test` | Verifies `includes/` subtree is skipped but `guides/includes/` is not | `TmpDir` with `page.md`, `includes/frag.md`, `guides/includes/keep.md` | Exactly 2 pages: `guides/includes/keep` and `page` | `includes/` root-only reservation, nested-includes non-reservation |
| `"scan: ignores .txt and case-variant .MD extensions"` | `test` | Verifies `.txt`, `.MD`, `.MDX`, `.Md` are all ignored; `.md` and `.mdx` are accepted | `TmpDir` with 6 files across 4 extension variants | Exactly 2 pages (`keep.md` and `keep.mdx`), same entity_id, both retained for EDUPLICATEID | Case-sensitive extension policy, duplicate-id preservation |
| `"scan: explicit Textile mode discovers only lowercase .textile pages"` | `test` | In `.textile` input mode, verifies `.textile` accepted and `.TEXTILE` / `.txt` ignored | `TmpDir` with 3 files | Exactly 1 page: `index.textile` with kind `.textile` | Textile-mode extension policy |
| `"scan: input families fail closed instead of mixing or guessing"` | `test` | Mixed-content dir triggers `InputFormatMismatch` for both Markdown and Textile scan modes | `TmpDir` with `index.textile` + `legacy.md` | `error.InputFormatMismatch` from both scan calls | Cross-family hard-error contract |
| `"scan: missing content root"` | `test` | Confirms nonexistent path returns `ContentDirMissing` | Hardcoded nonexistent path | `error.ContentDirMissing` | Root-missing error contract |
| `"scan: rejects directory symlink without following"` | `test` | Creates a directory symlink; expects `SymlinkRejected` before any entries under it are seen | `TmpDir` with a real dir, a dir symlink, and a root `.md` file; skipped on Windows / `AccessDenied` | `error.SymlinkRejected` | Directory symlink rejection, non-follow guarantee |
| `"scan: rejects page-file symlink"` | `test` | Creates a file symlink named `alias.md`; expects `SymlinkRejected` | `TmpDir` with `real.md` and `alias.md` symlink; skipped on Windows / `AccessDenied` | `error.SymlinkRejected` | Page-file symlink rejection |
| `"scan: duplicate entity ids preserved for later diagnostics"` | `test` | Creates `same.md` and `same.mdx`; expects both retained with tie-break on `source_path` | `TmpDir` with two same-stem files | 2 entries, identical entity_id `"same"`, sorted `same.md` before `same.mdx` | Duplicate-id preservation, tie-break sort |

***

## Policy-case walkthrough

### Case: recursive discovery with real fixture tree

**Behavior under test:**
`scan` is invoked with `content_root = "fixtures/content/valid"`. The fixture tree contains `empty-no-fm.md` (zero-byte), `satellite-child.md`, `trunk-root.md` at the root, and `nested/deep/page.md` one level deep. 

**Contract exercised:**
Recursive walk enters a real subdirectory (`nested/deep/`). Inode is recorded in `visited_dirs`. `page_mod.sortPages` is called at the end.

**Expected response:**
Exactly 4 `Page` entries, sorted by entity_id: `empty-no-fm`, `nested/deep/page`, `satellite-child`, `trunk-root`. All `source_path` values are content-root-relative with `/` separators, no leading `/`, no backslashes. All `output_path` values end in `.html` and have no leading `/` or `..` components. The `nested/deep/page` entry has `kind == .md`.

**What the test does not cover:**
The test confirms field values but does not re-scan and compare output across multiple runs to verify determinism against OS enumeration variation. It also does not test behavior when the fixture tree changes between calls.

**Evidence strength:** Directly demonstrated.

**Residual gap:**
No inode-cycle path is triggered here. The `scanDir` (non-format-specifying) entry point is not separately tested; it delegates to `scanDirFormat` with `.markdown`, which is covered, but that delegation is not directly observed by any test assertion.

***

### Case: sort independence from filesystem creation order

**Behavior under test:**
Five files are written to a `TmpDir` in reverse-alphabetical entity-id order (`z-last.md`, `a-first.md`, `m-mid.md`, `nested/z-nested.md`, `nested/a-nested.md`). The scanner is then invoked. 

**Contract exercised:**
`page_mod.sortPages` must produce a result that does not depend on filesystem enumeration order. The contract requires `entity_id` ascending as the primary key.

**Expected response:**
The five entries appear in strict ascending entity_id order: `a-first`, `m-mid`, `nested/a-nested`, `nested/z-nested`, `z-last`.

**What the test does not cover:**
The test uses a single scan; it does not demonstrate idempotence across multiple scans of the same directory or across different operating systems with different `readdir` orderings.

**Evidence strength:** Directly demonstrated.

**Residual gap:**
Nested directory (`nested/`) is entered before flat siblings are registered; the sort happens post-walk, so walk order is irrelevant — but this is not separately proven by a test that produces mixed results before sort. Whether `nested/` children appear before or after root-level files before sort is unobservable from the test assertions alone.

***

### Case: `includes/` root reservation with nested non-reservation

**Behavior under test:**
A `TmpDir` contains `page.md`, `includes/frag.md`, and `guides/includes/keep.md`. The scanner is invoked in default Markdown mode. 

**Contract exercised:**
The `includes/` path comparison `std.mem.eql(u8, entry.path, "includes")` must skip the directory before `walker.enter` is called on it. The nested path `guides/includes` must not be skipped.

**Expected response:**
Exactly 2 pages: `guides/includes/keep` (entity_id) and `page`. The `includes/frag.md` file is never registered.

**Defense-in-depth:**
The file-registration path also contains a guard checking `entry.path == "includes"` or `startsWith(entry.path, "includes/")`. This would catch any file-system walker that somehow delivered file entries under `includes/` without delivering a directory entry first.

**Evidence strength:** Directly demonstrated.

**Residual gap:**
The test does not verify that `includes/frag.md` was never even stat'd — only that it is absent from the output. The behavior of the secondary `includes` guard in `registerPage` is not independently exercised by a test where the directory guard fails.

***

### Case: cross-family hard-error (InputFormatMismatch)

**Behavior under test:**
A `TmpDir` contains both `index.textile` and `legacy.md`. Two separate scans are performed: one in default Markdown mode, one in explicit Textile mode. 

**Contract exercised:**
`InputFormat.accepts(entry_kind)` returns `false` for the cross-family extension. The scanner must return `error.InputFormatMismatch` rather than silently skipping or accepting the alien file.

**Expected response:**
Both scans return `error.InputFormatMismatch`. The specific file that triggers the error is whichever the walker encounters first; the test does not assert which file caused it.

**Forbidden unsafe response:**
The scanner must not silently include the mismatched file in the output. It must not guess the dialect. It must fail the entire scan rather than emitting a partial list.

**Evidence strength:** Directly demonstrated.

**Residual gap:**
The test does not confirm which file triggers the error. On a filesystem that enumerates alphabetically, `index.textile` would be encountered before `legacy.md`, so in the Markdown scan `index.textile` causes the error; `legacy.md` causes it in the Textile scan. This is not asserted. The test does not cover a tree with a cross-family file deep in a subdirectory (only root-level files are used).

***

### Case: symlink rejection (directory and page-file)

**Behavior under test (directory symlink):**
A `TmpDir` is set up with `real/` (a real directory containing `page.md`), `link` (a directory symlink to `real/`), and `root.md`. The test is skipped on Windows and on `AccessDenied`/`PermissionDenied`. 

**Walker interaction:**
The `Io.Dir.SelectiveWalker` emits the symlink as an entry with `entry.kind == .sym_link`. The scanner checks this before any `stat` call and immediately returns `error.SymlinkRejected`.

**Expected response:**
`error.SymlinkRejected` is returned. The scanner does not follow the symlink, does not read `real/page.md` through the link path, and does not register `root.md` (because the walk is aborted).

**Behavior under test (page-file symlink):**
A `TmpDir` contains `real.md` and `alias.md` (a symlink to `real.md`). The walker emits `alias.md` as a symlink entry. The scanner returns `error.SymlinkRejected` at the `entry.kind == .sym_link` check. 

**Defense-in-depth for file entries:**
For file entries that pass the `entry.kind` check (i.e., the walker reports `.file`), a secondary `statFile(..., .{ .follow_symlinks = false })` call is made. If that stat reports `st.kind == .sym_link`, the scanner returns `error.SymlinkRejected`. This catches symlinks that the walker might misclassify.

**Forbidden unsafe response:**
The scanner must not follow directory symlinks (which could loop or escape the content root). It must not register page-file symlinks as first-class pages (which would allow duplicate identity injection). It must not `stat` through a symlink when determining entry kind.

**Evidence strength:** Directly demonstrated for the first-layer check (walker kind). The second-layer (stat-based) check is structurally present in the code but not independently exercised by a test that isolates it (both tests exercise the first-layer check since `alias.md` is reported as `.sym_link` by the walker).

**Residual gap:**
No test exercises the case where the walker reports a symlink as `.file` but `statFile` with `follow_symlinks = false` reveals it is a `.sym_link`. The defense-in-depth `stat` gate has no dedicated test.

***

### Case: duplicate entity ids preserved for later diagnostics

**Behavior under test:**
`same.md` and `same.mdx` are in the same directory, producing identical entity_id `"same"` from path derivation. 

**Contract exercised:**
`registerPage` must not deduplicate. Both `Page` records must survive into the sorted output.

**Expected response:**
`list.len() == 2`. Both entries have `entity_id == "same"`. The tie-break on `source_path` places `same.md` before `same.mdx` because `"same.md" < "same.mdx"` lexicographically.

**Downstream intent:**
Both entries must be visible to the graph stage so it can emit `EDUPLICATEID` with both source paths. The scanner does not itself emit any diagnostic.

**Evidence strength:** Directly demonstrated.

**Residual gap:**
The test only covers `.md`/`.mdx` same-stem duplication. True same-path duplication (the same file appearing twice) cannot occur from a single selective walk. The test does not verify that neither record in the duplicate pair is dropped by any ordering-dependent logic.

***

## Control flow

```text
scan(io, options, out)
    → open content_root relative to CWD
        ├─ FileNotFound | NotDir  → error.ContentDirMissing
        └─ other I/O error        → propagated
    → scanDirFormat(io, content_dir, options.input_format, out)

scanDirFormat(io, content_dir, input_format, out)
    → stat content_dir → FsIdentity → push to visited_dirs
    → content_dir.walkSelectively(list_gpa) → walker

    loop: walker.next(io)
        ├─ null                          → break
        ├─ entry.kind == .sym_link       → error.SymlinkRejected
        ├─ entry.kind == .directory
        │    ├─ entry.path == "includes" → continue (skip whole subtree)
        │    ├─ entry.basename ends ".assets" → continue
        │    ├─ statFile(follow=false)
        │    │    ├─ not .directory      → continue
        │    │    └─ FsIdentity seen?    → error.SymlinkCycle
        │    │       else: append id, walker.enter
        │    │             SymLinkLoop   → error.SymlinkCycle
        │    └─ continue
        ├─ entry.kind != .file           → continue
        ├─ !identity.isPageFile(basename)→ continue (unknown / uppercase ext)
        ├─ identity.contentKind → error  → continue (not reached from isPageFile path)
        ├─ !input_format.accepts(kind)   → error.InputFormatMismatch
        ├─ includes defense-in-depth     → continue
        ├─ statFile(follow=false)
        │    ├─ kind == .sym_link        → error.SymlinkRejected
        │    └─ kind != .file            → continue
        └─ registerPage(retain, out, entry.path)

    page_mod.sortPages(out.pages.items)
    → return

registerPage(retain, out, walk_path)
    → identity.canonicalize(retain, walk_path) → source_path
    → identity.canonicalEntityId(retain, source_path) → entity_id
    → identity.safeOutputRelativePath(retain, entity_id) → output_path
    → identity.contentKind(source_path) → kind
    → out.append(Page{ source_path, entity_id, output_path, kind })
```


***
