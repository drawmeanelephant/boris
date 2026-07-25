---
title: "`tools/migration-lab/asset_filename.zig` evidence and cases"
id: docs/tools/migration-lab/asset_filename/evidence-and-cases
parent: docs/tools/migration-lab/asset_filename
status: draft
tags: [boris, zig, tools, evidence, migration-lab, asset_filename]
---

# `tools/migration-lab/asset_filename.zig` evidence and cases

## Operational walkthroughs

### Default asset-filename sanitization run

**Invocation:**

```bash
zig build run -- --mode=asset-filename \
  --root=./fixtures/hostile-asset-filenames \
  --out=./.asset-filename-out
```

**Inputs:**
All `.md`/`.mdx` files and sibling `.assets/` trees under `fixtures/hostile-asset-filenames` (or its `content/` subdirectory if present).

**Execution path:**
`main.zig` parses flags, resolves `Options{.root_dir, .out_dir, .quiet}`, calls `asset_filename.run(io, allocator, options)`. Inside `run`: source guard → root open → page discovery and sort → asset collection → per-asset classify/sanitize/copy → per-page Markdown rewrite → output publication.

**Outputs:**
`content/**` (sanitized pages and asset trees), `asset_filename_manifest.json`, `rewrite_manifest.json`, `report.json`, `REPORT.md` under `.asset-filename-out/`.

**Deterministic properties:**
Lexicographically sorted page and asset discovery; fixed JSON field order; no timestamps; SHA-256 computed from source bytes. Byte-identical on repeated runs (directly demonstrated by fixture test).

**Failure behavior:**
`OutputInsideSource` if `--out` is inside `--root`. `SourceNotFound` if `--root` is inaccessible. `Collision` on destination collision with differing bytes. `IoFailure` on write errors. All failures propagate to `main.zig` which maps to exit code 3; partial output may exist in `--out` at the point of failure. No rollback.

**Evidence strength:** Directly demonstrated (hostile fixture + determinism test).

**Residual gap:**
Exact behavior for very large files (memory exhaustion), case-insensitive host filesystems (case-collision at the OS level rather than the map level), and symlinks in the source root directory itself (as opposed to within `.assets/`) are not separately tested.

***

### Already-safe content tree

**Invocation:**

```bash
zig build run -- --mode=asset-filename \
  --root=./my-already-clean-content \
  --out=./.cleaned-out
```

**Inputs:**
A content tree where all asset filenames already satisfy `[A-Za-z0-9._-]+`.

**Execution path:**
Same as default. `isBorisSafeWithinTree` returns `true` for every asset; all records have `action: "unchanged"`. Asset bytes are still copied verbatim; Markdown files are copied without body modification.

**Outputs:**
`content/**` (verbatim copies), `asset_filename_manifest.json` (all records `action: "unchanged"`), `rewrite_manifest.json` (empty entries array), `report.json`, `REPORT.md`.

**Evidence strength:** Structurally checked (the `unchanged` branch exists in code and is tested by the `ready note` case in the image-path fixture).

**Residual gap:** Whether the tool skips writing unchanged content vs. always copies bytes is uncertain from the evidence reviewed; the safest interpretation is that bytes are always copied.

***

### Hostile Markdown traversal destinations

**Invocation:** Same as default run against a fixture containing `![img](../../../etc/secret.png)` style Markdown destinations.

**Execution path:**
During Markdown rewrite, the tool detects `../`-containing reference targets, classifies them as traversal, and leaves them unrewritten. A `rewrite_manifest.json` row is written with `reason: "traversal_dest_left_for_review"` (exact reason string uncertain).

**Outputs:**
Original `../…` reference preserved in Markdown body. Manifest records the unrewritten destination for human review.

**Evidence strength:** Documented contract (README safety rule 10, README mode description step 9); tested via `escape` page case in `image-path-starlight` fixture (which tests the same policy for the Starlight mode; direct asset-filename-mode traversal test is in the hostile-asset-filenames fixture).

**Residual gap:** Exact reason string in manifest is uncertain from evidence reviewed.

***

### Output collision abort

**Invocation:** Two source assets whose names sanitize to the same Boris-safe destination, or a case collision (e.g., `Photo.PNG` and `photo.png`).

**Execution path:**
After computing the sanitized destination, the collision map (keyed by ASCII-lowercased within-tree destination) is checked. If the key is already present for a different source path, the later asset record has `action: "rejected"` with `reason: "collision"` or `reason: "case_collision"`. The asset is not copied and the destination is not written.

**Evidence strength:** Directly demonstrated (hostile fixture includes case-collision and sanitized-name-collision cases; manifest entries are spot-checked).

**Residual gap:** Whether a `Collision` error is also propagated as a fatal return from `run`, or whether collisions are silently recorded in the manifest and the run continues successfully, is not confirmed from the evidence reviewed.

***

## Control flow

```text
process entry (main.zig)
    → parse CLI arguments
    → resolve mode = asset-filename
    → build Options{root_dir, out_dir, quiet}
    → call asset_filename.run(io, allocator, options)

run()
    → refuseOutputInsideSource(root_dir, out_dir)
    → open source root (prefer root/content if present)
    → walk source tree → collect PageEntry list
    → sort PageEntry list lexicographically by path
    → for each PageEntry:
        → walk sibling {stem}.assets/ directory
        → for each asset file:
            → isSymlink? → record rejected("symlink"); skip
            → isBorisSafeWithinTree? → record unchanged; copy bytes
            → else:
                → sanitizeWithinTree(within_tree_source)
                → asciiLowerAlloc → check case-collision map
                → collision? → record rejected("collision"); skip
                → readFileAlloc(source asset)
                → sha256Hex(bytes)
                → writeBytes(out, dest_path, bytes)
                → record rewritten(source, dest, sha256, bytes)
    → for each PageEntry:
        → readFileAlloc(source Markdown page)
        → build rewrite list from asset records for this page
        → rewriteMarkdownDestinations(body, rewrites) [fence-aware, longest-match]
        → writeBytes(out, content/{page-path}, rewritten_body)
        → record RewriteRecord entries
    → serialize asset_filename_manifest.json → writeBytes(out)
    → serialize rewrite_manifest.json → writeBytes(out)
    → serialize report.json → writeBytes(out)
    → serialize REPORT.md → writeBytes(out)
    → return void (or propagate first error)
```


***

## Tests, fixtures, and evidence coverage

| Test or fixture | Scope | Property demonstrated | Evidence strength | Not demonstrated |
| :-- | :-- | :-- | :-- | :-- |
| `test "asset_filename isBorisSafeWithinTree"` (inline) | `isBorisSafeWithinTree` function | Safe/unsafe path classification for representative inputs including `..`, `/`-leading, unicode, safe ASCII | Directly demonstrated | Exhaustive property coverage; all byte values |
| `test "asset_filename sanitizeSegment"` (inline) | `sanitizeSegment` | URL-decode → dash-collapse → dot-dash removal; fallback to `"asset"` | Directly demonstrated | All segment patterns; empty-after-sanitize |
| `test "asset_filename joinNormalized resolves and rejects escape"` (inline) | `joinNormalized` helper + `isBorisSafeWithinTree` + `pageStemFromEntity` + `pageDirFromLocaleRel` | Path join safety; traversal rejection; stem/dir extraction | Directly demonstrated | All escape forms |
| Hostile asset-filenames fixture test | Full `run` call on `fixtures/hostile-asset-filenames/` | Spaces, Unicode, `%20` names, nested dirs, case collision, sanitized-name collision, traversal refs, symlink | Directly demonstrated | Symlink committed in git (uncertain); cross-platform |
| Hostile fixture determinism test | Two sequential `run` calls; manifest byte comparison | Byte-identical repeated runs on hostile input | Directly demonstrated | Cross-platform; different filesystems |
| Image-path-starlight fixture (F-L1) | `starlight.run` which shares some image-migration logic | Relative sibling asset, nested, missing, escape, already-correct, public paths | Directly demonstrated (for Starlight mode) | Direct asset-filename-mode coverage of same matrix |
| Source immutability assertion | Compare fixture source file bytes before/after `run` | Source tree not modified | Directly demonstrated | All file types; all modes |

**Not demonstrated by available evidence:**

- Allocation-failure paths (no `std.testing.allocator.setFailure` style test visible).
- Cross-platform byte-identity of output.
- CLI argument parsing edge cases (handled in `main.zig`, not this file).
- Behavior on case-insensitive host filesystems.
- Very large file handling (memory bounds).
- Stale-output cleanup (none implemented; not tested).
- Parallel or concurrent invocation safety.

***
