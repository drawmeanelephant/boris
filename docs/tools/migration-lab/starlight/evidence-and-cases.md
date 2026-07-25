---
title: "`tools/migration-lab/starlight.zig` evidence and cases"
id: docs/tools/migration-lab/starlight/evidence-and-cases
parent: docs/tools/migration-lab/starlight
status: draft
tags: [boris, zig, tools, evidence, migration-lab, starlight]
---

# `tools/migration-lab/starlight.zig` evidence and cases

## Operational walkthroughs

### Default Starlight conversion

**Invocation:**

```text
zig build run -- --mode starlight --root ./fixtures/dogfood-starlight --out ../dogfood-sl-out --locale en --max-pages 80
```

**Inputs:** `fixtures/dogfood-starlight/src/content/docs/` (root-locale shape, 67 pages), `public/` for absolute image refs, `astro.config.*` for nav text-scan.

**Execution path:** `main.parseOptions` → `starlight.run()` → `discoverContentRoot` (root-locale) → `collectMarkdownFiles` → lexicographic sort → `parseFrontmatterLite` per page → `stripUntrustedBlocks` → `transformStarlightMdx` → link rewrite → `neutralizeDynamicAssetAttrs` → `enrichAssetsWithHashes` → `emitPage` / `emitSyntheticTrunk` → write `content/*.md` → write `content/*.assets/*` → serialize all manifests.

**Outputs:** `content/*.md`, `content/*.assets/*`, all sidecar JSONs, `REPORT.md`.

**Deterministic properties:** Lexicographic discovery order; stable manifest sort; no timestamps in body; SHA-256 hashes for migrated assets.

**Failure behavior:** `error.ContentRootNotFound` if no `src/content/docs/` exists → propagates to `main` → stderr message + exit 3.

**Evidence strength:** Directly demonstrated — the dogfood fixture test runs the full pipeline and checks for presence of expected content and asset migration.

**Residual gap:** `report.json` and `REPORT.md` generation not exhaustively tested for field completeness; stale file behavior not tested.

***

### Hostile / adversarial fixture run

**Invocation:**

```text
zig build run -- --mode starlight --root ./fixtures/hostile-starlight --out <outdir> --locale en --max-pages 40
```

**Inputs:** `fixtures/hostile-starlight/` — entity collisions, deep paths, Unicode filenames, unsupported MDX, instruction fences, ambiguous routes.

**Execution path:** Same as above; collision records go to `unsupportedmanifest.json`; instruction fences are stripped via `stripUntrustedBlocks`; unresolvable links become `linkreview.json` rows with `review` resolution.

**Outputs:** Same artifact set; `boundarymanifest.json` contains `stripped` entries for each directive/prompt fence.

**Deterministic properties:** Two-run byte-identity of `boundarymanifest.json` is directly tested by the hostile fixture test.

**Failure behavior:** Entity collisions are handled gracefully (disambiguation suffix), not as errors. Unresolvable links are reviewed, not failed.

**Evidence strength:** Directly demonstrated.

**Residual gap:** Unicode path behavior on case-insensitive filesystems not tested.

***

### Image-path migration fixture

**Invocation:**

```text
zig build run -- --mode starlight --root ./fixtures/image-path-starlight --out <outdir>
```

**Inputs:** `fixtures/image-path-starlight/` — relative sibling images, nested paths, missing images, path-escape attempts, public-absolute images.

**Execution path:** `migratePageImages` (or equivalent) → `joinNormalized` for relative resolution → `isBorisSafeWithinTree` → `sha256Hex` → copy bytes → rewrite Markdown refs.

**Outputs:** Migrated assets under `content/features/alpha.assets/`; `assetsmanifest.json` with SHA-256 entries; `linkreview.json` with `referencedassetmissing`, `assetpathescapesmigrationroot` review reasons.

**Deterministic properties:** Two-run byte-identity of `content/features/alpha.md` and `assetsmanifest.json` directly tested.

**Failure behavior:** Missing image → `referencedassetmissing` review event, original Markdown line unchanged. Path escape → `assetpathescapesmigrationroot` review event, line unchanged. Invalid Boris-safe path → `assetpathinvalidornotborissafe`.

**Evidence strength:** Directly demonstrated.

**Residual gap:** `public/` absolute image resolution not tested for all edge cases (e.g., absolute paths with query strings).

***

### Dynamic asset attribute sanitization

**Invocation:** Any Starlight run where source MDX contains JSX tags with dynamic `src={localImage.src}` or similar expressions.

**Execution path:** `neutralizeDynamicAssetAttrs` per line → JSX expression replaced by review placeholder in output body → `LinkEvent` with `kind: dynamicasset`, `reviewreason: dynamicassetexpression` appended to events.

**Outputs:** Output Markdown has dynamic expression omitted with review placeholder; `boundarymanifest.json` contains the review event; static attributes preserved byte-for-byte.

**Failure behavior:** If `findJsxExpressionEnd` cannot locate the expression end, the attribute is left unchanged and no event is emitted.

**Evidence strength:** Directly demonstrated by `test "starlight sanitize dynamic asset expression keeps exact review event"`.

**Residual gap:** Complex nested JSX expressions may not be fully captured by the bracket-counting parser.

***

### Relation candidate extraction

**Invocation:** Automatic during any Starlight run when pages contain known Filed-shaped fields (`relatedEntries`, `relatedHaiku`, `relatedLimerick`, `relatedLorelog`, `mascotRef`, `concepts`, `escalationPath`).

**Execution path:** `extractRawRelationValues` → `splitFrontmatterLines` → `topLevelField` → `parseInlineRelationValues` / `parseBlockRelationValues` → `collectRelationCandidatesForPage` → `resolveRelationTarget` → `collectRelationCandidates` (sort) → write `relationcandidates.json`.

**Outputs:** `relationcandidates.json` sorted by `sourceentity` → `sourceline` → `valueindex` → `sourcefield` → `rawvalue`.

**Deterministic properties:** Explicit multi-field sort comparator; structurally checked.

**Failure behavior:** Malformed YAML lists/objects → entire value preserved as single review row with `reviewreason: malformedinlinelist` or `nonscalarblock`. Self-targets → `selftargetnotproductrelation`. Duplicate tuples → first wins ordinal, later copies get `duplicateproductrelation`.

**Evidence strength:** Structurally checked; not covered by a dedicated fixture test in the available evidence.

**Residual gap:** No golden-output fixture test for `relationcandidates.json` evident in available source.

***

### Help / usage path

**Invocation:** `zig build run -- --help`

**Execution path:** `main.parseOptions` sets `opts.help = true` → `printUsage()` → `return ExitCode.success.int` (exit 0). `starlight.run()` is never called.

**Evidence strength:** Directly demonstrated by `main.zig` source.

***

### Invalid CLI invocation

**Invocation:** `zig build run -- --mode starlight --root /same/dir --out /same/dir`

**Execution path:** `main.main` detects `opts.rootdir == opts.outdir` → `std.log.err(...)` → `return ExitCode.usage.int` (exit 2). `starlight.run()` is never called.

**Evidence strength:** Directly demonstrated by `main.zig` source.

***

## Control flow

```text
process entry (main.zig: main())
    → initialize arena allocator, GPA, io
    → collect process args via init.minimal.args.toSlice()
    → parseOptions() → RunOptions or exit 2 on error
    → if opts.help → printUsage() + exit 0
    → switch opts.mode → .starlight branch
        → check opts.rootdir != opts.outdir or exit 2
        → starlight.run(io, gpa, RunOptions{...})
            → open source root as read-only Io.Dir
            → discoverContentRoot()
                → check src/content/docs exists
                → probe locale-dir shape (src/content/docs/<locale>/)
                → fallback to root-locale shape (src/content/docs/)
                → return ContentRoot or error.ContentRootNotFound
            → collectMarkdownFiles() into ArrayList
            → sort paths lexicographically
            → for each candidate path:
                → parseFrontmatterLite() → title, frontmatter, body, unmapped
                → entityIdFromLocaleRel() → entity ID
                → routeFromEntity() → route
                → outputPathFromEntity() → output path
                → isCandidatePage() filter
                → apply --max-pages cap
                → detect and record entity collisions (disambiguation suffix)
            → for each selected page:
                → stripUntrustedBlocks() → clean body + stripped blocks
                → transformStarlightMdx() → component-mapped body + events
                → neutralizeDynamicAssetAttrs() → sanitized body + asset events
                → link rewrite pass (Markdown links → entity IDs when resolvable)
                → attribute link scan (href/to scan, inventory only)
                → migratePageImages() → copy assets, rewrite refs, review events
            → enrichAssetsWithHashes() → SHA-256 and size on asset entries
            → collectRelationCandidates() → sorted relation candidate rows
            → emitPage() / emitSyntheticTrunk() → Markdown bytes
            → write content/*.md to --out
            → write content/*.assets/* to --out
            → serialize and write all JSON manifests
            → write REPORT.md
            → optional: invoke boris binary → write compilereport.json
            → return void or propagate error
    → if error → std.log.err + return ExitCode.ioerror.int (exit 3)
    → exit 0
```


***

## Tests, fixtures, and evidence coverage

| Test or fixture | Scope | Property demonstrated | Evidence strength | Not demonstrated |
| :-- | :-- | :-- | :-- | :-- |
| `test "starlight F-L1 image-path fixture migrates, preserves, and fails closed"` | Integration (image-path-starlight fixture) | Relative image copy, public image copy, missing image → review, escape → review, source immutability, two-run byte-identity of page + assetsmanifest | Directly demonstrated | Symlink handling, cross-platform |
| `test "starlight dynamic asset attributes become explicit review placeholders"` | Integration (dynamic-asset-starlight fixture) | Dynamic JSX `src={expr}` replaced with review placeholder; `linkreview.json` contains `dynamicassetexpression` | Directly demonstrated | Complex nested JSX |
| `test "starlight sanitize dynamic asset expression keeps exact review event"` | Unit | `neutralizeDynamicAssetAttrs` produces correct event for `src={localBirdImage.src}` | Directly demonstrated | Edge cases of malformed JSX |
| `test "starlight sanitizeMdxBody preserves attributed Aside and Details"` | Unit | `&lt;Aside type="note" title="...">` and `&lt;Details>` preserved byte-for-byte | Directly demonstrated | All component variants |
| `test "starlight joinNormalized resolves and rejects escape"` | Unit | `joinNormalized` rejects `../../../../secret.png`; `isBorisSafeWithinTree` rejects `..x.png`, café filename | Directly demonstrated | Windows path separators |
| Hostile-starlight two-run test | Integration (hostile-starlight fixture) | `boundarymanifest.json` byte-identity across two runs | Directly demonstrated | Stale file cleanup |
| Dogfood-starlight test | Integration (dogfood-starlight, 67 pages) | Full pipeline at realistic scale; image migration; nav; MDX components; compile report | Directly demonstrated | Allocation failure paths |
| Fixture: `fixtures/image-path-starlight/` | Input fixture | Source asset resolution matrix | Supporting evidence | — |
| Fixture: `fixtures/hostile-starlight/` | Input fixture | Adversarial entity collisions, instruction fences, deep paths | Supporting evidence | — |
| Fixture: `fixtures/dogfood-starlight/` | Input fixture | Root-locale 67-page realistic dogfood tree | Supporting evidence | — |
| Fixture: `fixtures/mini-starlight/` | Input fixture | Compact locale-dir proof | Supporting evidence | — |
| Fixture: `fixtures/mini-starlight-root/` | Input fixture | Compact root-locale proof | Supporting evidence | — |
| Fixture: `fixtures/dynamic-asset-starlight/` | Input fixture | Dynamic JSX asset attribute in MDX | Supporting evidence | — |

**Not demonstrated by tests:**

- Stale output file cleanup (not implemented).
- Cross-platform byte-identity.
- Symlink handling.
- Allocation failure recovery.
- `relationcandidates.json` golden output comparison.
- All `report.json` / `REPORT.md` fields.
- `headingfragments.json` content verification.
- `compilereport.json` content when Boris binary is absent.

***
