---
title: "`src/assemble.zig` surface and execution"
id: docs/boris/src/assemble/surface-and-execution
parent: docs/boris/src/assemble
status: draft
tags: [boris, zig, source-reference, surface, assemble]
---

# `src/assemble.zig` surface and execution

## Module structure

1. **Marker and bound constants** — `contentmarker`, `navmarker`, … `footermarker`, `asseturlprefix`, `maxsegments` (32), `maxasseturls` (16), `writebuffersize` (64 KiB).
2. **Errors and plan types** — `LayoutError`, `Slot`, `Segment`, `Layout`, `SlotValues`.
3. **Asset-url grammar** — `validateAssetUrlPath`.
4. **Split / load** — `Layout.split`, `loadLayout`, append helpers, content-only `prefix`/`suffix` convenience.
5. **Directory helpers** — `ensureParentPath`, `precreateOutputDirs`, atomic-temp scrub helpers.
6. **Publish API** — `WritePageOptions`, `writePage` / `writePageOpts`, `writePageWithSlots` / `writePageWithSlotsOpts`.
7. **Test double** — `HoldUntilFlush` (fingerprint slices; detect premature invalidation), `spliceToHold` / `spliceToHoldSlots`.
8. **Embedded tests** — split matrix, asset-url rejects, sequential splice, replace-over-prior, failed-write keeps prior, flush-before-reset.

***

## Exported public surface

| Symbol | Kind | Purpose |
| :-- | :-- | :-- |
| `contentmarker` … `footermarker` | `[]const u8` | Exact `&#123;&#123;…&#125;&#125;` token spellings |
| `asseturlprefix` | `[]const u8` | `"asset-url "` prefix for helper form |
| `maxsegments` / `maxasseturls` | `usize` | Closed plan caps |
| `writebuffersize` | comptime int | Stack writer buffer for page IO |
| `LayoutError` | error set | Load/split failures |
| `Slot` | enum | `content`, `nav`, `breadcrumb`, `title`, `toc`, `children`, `metadata`, `footer` |
| `Segment` | union(enum) | `static` \| `slot` \| `asseturl` |
| `Layout` | struct | `raw`, fixed segment/asset arrays, slot flags, optional `prefix`/`suffix` |
| `Layout.split` | fn | Plan from raw template bytes |
| `Layout.segmentsSlice` / `assetPaths` | fn | Views of filled plan |
| `SlotValues` | struct | Per-page slot strings + `assethrefs` |
| `SlotValues.forSlot` | fn | Slot → bytes |
| `validateAssetUrlPath` | fn | Theme-relative path rules |
| `loadLayout` | fn | Read file into arena + `split` |
| `ensureParentPath` | fn | `createDirPath` for nested output |
| `precreateOutputDirs` | fn | Batch parent dirs for a page set |
| `isAtomicTempName` / scrub helpers | fn | Best-effort cleanup of 16-hex temps |
| `writePage` / `writePageOpts` | fn | Content-only convenience over slots API |
| `writePageWithSlots` / `writePageWithSlotsOpts` | fn | Stream plan + atomic replace |
| `WritePageOptions` | struct | `failbeforepublish` test injection |
| `HoldUntilFlush` | struct | Test sink proving flush-before-reset |
| `spliceToHold` / `spliceToHoldSlots` | fn | In-memory sequential splice for tests |

Private: marker scan loop, `appendStatic` / `appendSlot` / `appendAssetUrl`, hex-temp counting.[^4_1]

***

## Bounds and allowlists

- **Required marker:** exactly one `&#123;&#123;content&#125;&#125;`. Missing → `MissingContentMarker`; second → `DuplicateContentMarker`.[^4_1]
- **Optional slots (at most one each):** `nav`, `breadcrumb`, `title`, `toc`, `children`, `metadata`, `footer`. Duplicates → `DuplicateLayoutMarker`.[^4_1]
- **Unknown `&#123;&#123;…&#125;&#125;`:** `UnknownLayoutMarker` (includes unclosed `&#123;&#123;` regions treated as invalid).[^4_1]
- **Segments:** ≤ 32 total static/slot/asseturl pieces.[^4_1]
- **`asset-url`:** form `&#123;&#123;asset-url PATH&#125;&#125;` with single space after the name; PATH non-empty, no internal spaces after trim mismatch, must start with `assets/`, `/`-separated only, no empty/`.`/`..` segments, no absolute/drive/backslash, conservative ASCII `A-Za-z0-9._-` per segment; ≤ 16 distinct refs.[^4_1]
- **UTF-8:** validated on non-empty raw at `split` before marker scan. Content Markdown UTF-8 is owned by the parser, not assemble.[^4_1]

These are product policy checks at layout load — fail fast before content compile (`compile.loadLayoutOnce` remaps to `LayoutMissingMarker` / `LayoutDuplicateMarker` / etc.).[^4_2]

***

## Types and lifetime

`Layout.raw` is the full template buffer (arena-owned after `loadLayout`). Every `Segment.static` and `asseturl` path is a **slice into `raw`** (zero-copy). Flags (`hasnav`, … `hasasseturl`) are set during split so compile can skip unused chrome work and decide whether site-nav fingerprint material is required.[^4_1]

Content-only layouts (no optional slots/asset-url) also fill legacy `prefix` / `suffix` around the single content slot for three-write tests and older call shapes. Multi-slot layouts leave `prefix`/`suffix` empty; consumers must walk `segmentsSlice`.[^4_1]

`SlotValues` strings are caller-owned for the duration of `writePage*` (typically Whiteboard arena). `assethrefs` is parallel to `Layout.assetPaths` in plan order — page-relative URLs computed by `identity.relativeHref` in compile, not by assemble.[^4_2][^4_1]

`HoldUntilFlush` stores up to a fixed number of part pointers plus Wyhash fingerprints; `flush` re-checks hashes before copy and returns `PrematureInvalidation` if the Whiteboard was wiped early. Production does not use this type — it documents the ordering invariant.[^4_1]

***

## Recognition rules (layout markers)

| Rule | Behavior |
| :-- | :-- |
| Token shape | `&#123;&#123;` … `&#125;&#125;`; scan is linear over raw |
| Content | Required once; becomes `.slot .content` |
| Named chrome | Exact marker strings only; set corresponding `has*` flag |
| asset-url | Prefix `asset-url ` + path + closing `&#125;&#125;`; validate then `.asseturl` |
| Static gaps | Non-empty spans between tokens → `.static` views |
| Unclosed `&#123;&#123;` | `UnknownLayoutMarker` |
| Empty static | Not appended (`appendStatic` no-ops on len 0) |

No nesting, conditionals, or partial markers. Authors edit HTML shells with literal mustache-like placeholders only.[^4_1]

***

## `Layout.split` / `loadLayout`

```text
loadLayout(io, dir, path, arena)
  → read entire file into arena
  → Layout.split(raw)

Layout.split(raw)
  → utf8ValidateSlice (if len > 0)
  → scan {{…}} tokens left-to-right
  → append static / slot / asseturl under caps
  → require seen content
  → optionally derive prefix/suffix for content-only plans
  → Layout
```

Allocation during split is stack/fixed arrays inside `Layout` — no heap for the plan spine. IO allocation is only the raw buffer on load.[^4_1]

**What it does not do:** resolve theme files on disk, expand includes, escape HTML, or validate that slot producers will supply non-empty chrome.[^4_1]

***

## HTML projection (stream publish)

### `writePageWithSlotsOpts`

1. `outdir.createFileAtomic(outputpath, .{ .replace = true, .make_path = true })`
2. Buffered writer (`writebuffersize`) over the temp file
3. For each plan segment: write static bytes, `slots.forSlot(slot)`, or next `assethrefs[i]`
4. `flush` writer
5. Optional test fault: `failbeforepublish` → `TestInjectedWriteFailure` (temp cleaned by `defer atomic.deinit`; final untouched)
6. `atomic.replace` → final name

`writePage` / `writePageOpts` are thin wrappers that only fill `.content`. Nested outputs rely on atomic `make_path` and/or `precreateOutputDirs` for batch parent creation under staging.[^4_1]

### Same-directory replace claims

Documented as atomic w.r.t. readers seeing old-or-new (not torn) on typical POSIX local volumes. Explicit non-claims: cross-device rename atomicity; universal behavior on every FS without multi-OS CI; Windows brief `AccessDenied` window for concurrent openers during replace. Stage-tree publish in compile may `copyFile`+delete on `error.CrossDevice` for completeness — that path is outside assemble’s per-page API.[^4_2][^4_1]

***

## Diagnostics / errors

| Error | Typical cause |
| :-- | :-- |
| `MissingContentMarker` | No `&#123;&#123;content&#125;&#125;` |
| `DuplicateContentMarker` | Two+ content markers |
| `DuplicateLayoutMarker` | Repeated optional slot |
| `UnknownLayoutMarker` | Bad or unclosed token |
| `TooManyLayoutSegments` | > 32 pieces |
| `InvalidAssetUrl` | Bad helper form or path grammar / href count mismatch at write |
| `TooManyAssetUrls` | > 16 asset-url markers |
| `InvalidUtf8` | Layout file not UTF-8 |
| `TestInjectedWriteFailure` | Test-only publish fault |

Compile remaps layout load errors to `Layout*` sentinels for exit-code classification (content vs IO). Assemble itself does not emit `diag.Diagnostic` rows.[^4_2][^4_1]

***

## Collaboration map

```text
layouts/*.html (arena-owned raw)
       │
       ▼
assemble.loadLayout / Layout.split ──► Layout (closed plan)
       │
       │   compile: htmlbody + htmlnav/toc + theme hrefs
       │            ──► SlotValues (Whiteboard)
       ▼
writePageWithSlotsOpts
       │  sequential writeAll(static|slot|href)
       │  flush → Atomic.replace
       ▼
dist / staging page.html

HoldUntilFlush (tests only) ── proves flush-before-reset
```

`build.zig` wires `assemble_mod` **without** a renderer link — pure Zig/IO. Product rendering stays in `htmlbody` / `aside` / `compile`.[^4_1]

***

## Residual risks and review notes

| Item | Classification | Notes |
| :-- | :-- | :-- |
| Cross-device final replace | Documented limitation | Prefer same-parent stage; copy+delete fallback lives in compile stage publish |
| Windows replace open window | Documented limitation | std notes possible brief `AccessDenied` for concurrent readers |
| `assethrefs` length mismatch | Confirmed guard | Write path returns `InvalidAssetUrl` if fewer hrefs than plan assets |
| Caller resets Whiteboard early | Likely misuse / UAF | API contract + HoldUntilFlush tests; no runtime lock |
| `maxsegments` / `maxasseturls` | Documented limitation | Hostile huge layouts fail closed; raise only with tests |
| Content-only `prefix`/`suffix` | Compatibility shim | Multi-slot layouts must not rely on them |
| Atomic temp scrub | Best-effort hygiene | 16-hex names only; interrupted runs cleaned at compile start |
| Parallel `--jobs` | Safe w.r.t. assemble | Per-page temps/final paths; no shared assemble mutable state |

**Phased suggestions (non-blocking):** keep new chrome behind exact markers + one-each flags; golden a multi-slot+asset-url fixture under `docs/contracts` if not already pinned; avoid introducing expression syntax in layouts.[^4_1]

***

## Acceptance criteria (module health)

- `zig build test` runs `assemble_tests` green (no renderer dependency).
- Bad layouts fail before content compile (`LayoutMissingMarker` / duplicate / unknown).
- Valid multi-slot layout streams nav/title/content in document order with theme `asset-url` hrefs resolved.
- `writePage` replace-over-prior and failed-write-preserves-prior pass on the host OS.
- HoldUntilFlush proves flush-before-reset; compile path only resets Whiteboard after publish returns.
- Default `layouts/main.html` splits cleanly (content + optional chrome markers used by Feature 6).[^4_2][^4_1]

***

## Confidence

| Area | Level | Basis |
| :-- | :-- | :-- |
| Marker grammar \& caps | High | Broad split unit matrix |
| Zero-copy segment views | High | Pointer-identity test + struct design |
| Sequential multi-slot stream | High | asset-url order + splice tests |
| Atomic publish / prior preserve | High | Dedicated IO tests + module docs |
| Cross-OS rename edge cases | Medium | Explicit non-claims; host `zig build test` only |
| Integration under `--jobs` / multi-target stage | High via compile | Assemble is pure per-call; stage commit owned by compile |

<!-- BORIS-SOURCE-DOC END -->
<span style="display:none">[^4_3]</span>

<div align="center">⁂</div>

[^4_1]: boris-source-1.md

[^4_2]: boris-source-2.md

[^4_3]: boris-source-3.md
