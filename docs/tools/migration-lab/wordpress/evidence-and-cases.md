---
title: "`tools/migration-lab/wordpress.zig` evidence and cases"
id: docs/tools/migration-lab/wordpress/evidence-and-cases
parent: docs/tools/migration-lab/wordpress
status: draft
tags: [boris, zig, tools, evidence, migration-lab, wordpress]
---

# `tools/migration-lab/wordpress.zig` evidence and cases

## Operational walkthroughs

### Default WordPress migration (WXR + local media)

**Invocation:**

```
zig build run -- --wxr fixtures/mini-wxr/export.xml --media fixtures/mini-wxr/media --out ../wp-report
```

**Inputs:**
WXR XML export; local media uploads directory; default `--out` replaced by explicit path.

**Execution path:**
`main.zig::main` → parses CLI → dispatches to `wordpress.run(io, gpa, opts)` → full pipeline as described in control-flow section below.

**Outputs:**
`content/<type>/<slug>.md` pages; `content/<slug>.assets/<file>` for matched media; `content/posts.md` and/or `content/pages.md` trunk stubs; `content/preserved*.md` for unsupported types and comments; `report.json`; `REPORT.md`; `mediamanifest.json`.

**Deterministic properties:**
Output page ordering by entity-ID; report arrays sorted explicitly. No timestamps in frontmatter. Media SHA-256 verified before copy.

**Failure behavior:**
XML parse error → exit 3. Unreadable WXR → exit 3. Output write failure → exit 3. Unreadable individual media files → rejected with reason code, not fatal. Stale `content/` delete failure → silently continued (residual gap).

**Evidence strength:** Directly demonstrated (mini-wxr and unit-wxr fixture tests).

**Residual gap:** Cross-platform byte identity not tested. Allocator-failure paths not directly tested. Very large WXR behavior unknown.

***

### Missing media (no `--media` flag)

**Invocation:**

```
zig build run -- --wxr fixtures/mini-wxr/export.xml --out ../wp-report
```

**Inputs:** WXR only; no media directory.

**Outputs:** Same Markdown tree but no `stem.assets/` directories. Media references in body are not rewritten. All media references appear as `mediaunverified` or `missingmedia` feature codes in report.

**Evidence strength:** Directly demonstrated (unit-wxr fixture: "Present media" and "Missing media" test matrix rows).

**Residual gap:** Behavior when `--media` is provided but empty directory not confirmed.

***

### Re-run into same `--out` directory

**Invocation:** Same command repeated.

**Inputs:** Same.

**Outputs:** `content/` deleted and recreated; sidecars deleted and recreated. Previous valid content not preserved during delete.

**Deterministic properties:** Structurally: identical inputs produce identical outputs. Byte-identity across runs: not demonstrated by dedicated repeated-run test.

**Failure behavior:** If `deleteTree` fails silently (caught error), prior content may persist and mix with new output. No diagnostic is emitted in this case.

**Evidence strength:** Structurally checked (wipe code present); directly demonstrated for output correctness; not demonstrated for partial-failure safety.

**Residual gap:** Silent failure on stale-output wipe.

***

### Invalid CLI invocation

**Invocation:**

```
boris-migration-lab --mode wordpress
# (missing --wxr)
```

**Outputs:** Error message to stderr; usage text printed; exit 2.

**Evidence strength:** Structurally checked (guard in `main.zig` before dispatch).

**Residual gap:** No direct test for every invalid-CLI case in available evidence.

***

## Control flow

```text
process entry (main.zig::main)
    → initialize arena + GPA allocators
    → parse CLI arguments
    → guard: --out != --wxr, --out != --media
    → dispatch to wordpress.run(io, gpa, opts)

wordpress.run
    → open WXR file, read into arena
    → parseWxr: pull-parse XML into WxrDocument
    → if --media: walk media tree, sort file list
    → index items by post-ID (HashMap)
    → index items by slug (HashMap, tracking duplicates)
    → build ItemMeta list (entity-ID, output-path per post/page)
    → detect colliding output paths; append --<postid> suffix to disambiguate
    → sort ItemMeta by entity-ID (lexicographic)
    → evaluate taxonomy cardinality; emit high-cardinality feature if threshold exceeded
    → evaluate media duplicate basenames; emit feature codes
    → build postid→entityid index
    → stale-output cleanup: deleteTree(content/), deleteFile(report.json, REPORT.md, mediamanifest.json)
    → open/create output directory
    → for each ItemMeta (post or page):
        → convertItemBody: WXR HTML→Markdown body, shortcode/block handling, link+media harvest
        → accumulate feature codes: post-format, taxonomy, high-cardinality terms
        → map parent: WP postparent → Boris parent entity; enforce one-hop; flag deep hierarchy
        → map status: publish/draft/future/private/password-protected → Boris status
        → flag: empty title, long title, empty body, empty slug, sticky post, excerpt
        → handle comments/trackbacks/pingbacks: emit preserved*.md; mark unsupported
        → match media references against local media tree:
            → strip query/fragment; percent-decode; try upload-key lookup; fallback basename
            → reject symlinks; flag ambiguous (duplicate basenames)
            → verify SHA-256 for copies; copy to stem.assets/
            → rewrite verified references in body
        → resolve internal links against WXR item corpus
        → build frontmatter + provenance comment
        → emit content/<type>/<slug>.md
        → accumulate PageRecord, Provenance, LinkFinding, MediaRef, FeatureFinding
    → preserve unsupported post types (attachment, nav_menu_item, wp:block, etc.)
    → emit trunk stubs (content/posts.md, content/pages.md) if applicable
    → build slug-conflict list from slug→IDs index
    → explicit sort: pages, parents, alllinks, allmedia, missing, mediamanifest,
                     allfeatures, slugconflicts, allcomments
    → emit report.json
    → emit REPORT.md
    → emit mediamanifest.json
    → optional progress message to stderr
    → return (or propagate error to main.zig → exit 3)
```


***

## Tests, fixtures, and evidence coverage

| Test or fixture | Scope | Property demonstrated | Evidence strength | Not demonstrated |
| :-- | :-- | :-- | :-- | :-- |
| Inline test: `mini-wxr` fixture run | Integration; runs full `wordpress.run` with `fixtures/mini-wxr` | Produces output without error; basic post/page/media paths present | Directly demonstrated | Exact byte output not compared; cross-platform identity |
| Inline test: `unit-wxr` fixture run | Integration; exercises full coverage matrix | Slug synthesis, duplicate slugs, status mapping, excerpt, sticky, empty slug, empty title, comments, hierarchy, deep hierarchy, missing media, present media, attachment, menu item, trunk stubs | Directly demonstrated | Allocation failure; adversarial XML; very large files |
| `fixtures/unit-wxr/README.md` coverage matrix | Documentation | Documents 30+ distinct behavioral cases mapped to post IDs | Documented contract | Not all cases confirmed as directly tested in available inline test code |
| `fixtures/mini-wxr/export.xml` + `media/` | Fixture | Small synthetic WXR with media present/absent | Test fixture (consumed by inline tests) | Not a golden comparison |
| `fixtures/mini-wxr/README.md` | Documentation | Documents posts, pages, authors, categories, tags, page hierarchy, media, shortcodes, draft statuses, duplicate slug, custom post type, attachment | Documented contract | — |
| `fixtures/wptt-derived/README.md` | Documentation | High-cardinality taxonomy and long-title hostile cases | Documented contract | Not confirmed as committed synthetic fixture (references external WPTT download) |
| `fixtures/media-wxr/README.md` | Documentation | Extended media reference matrix | Documented contract | Not confirmed as directly exercised inline test |
| Stale-output wipe | Implementation | `content/` deleted and sidecar files deleted on re-run | Structurally checked | Not isolated as a standalone test |
| Symlink rejection | Implementation | `isSymlink` check with `symlinkescape` code | Structurally checked | Not confirmed in `wordpress.zig` inline tests (hostile-asset-filenames tests may cover `assetfilename.zig` mode, not WP mode) |
| Determinism / repeated-run byte identity | None found | — | Uncertain | Completely unverified |
| Allocation failure | None found | — | Uncertain | — |
| Malformed XML | None found | — | Uncertain | — |
| Cross-platform CI | None found | — | Uncertain | — |


***
