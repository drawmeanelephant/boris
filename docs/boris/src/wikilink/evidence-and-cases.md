---
title: "`src/wikilink.zig` evidence and cases"
id: docs/boris/src/wikilink/evidence-and-cases
parent: docs/boris/src/wikilink
status: draft
tags: [boris, zig, source-reference, evidence, wikilink]
---

# `src/wikilink.zig` evidence and cases

## Test harness construction

The embedded tests run as part of the Boris test suite via `zig build test`. There is no separate test binary or root module for this file; the tests declared with `test "…" { … }` blocks at the bottom of `src/wikilink.zig` are compiled in when the build system includes `wikilink.zig` in the test step. All collaborators (`graph.zig`, `identity.zig`, `include.zig`, `diag.zig`) are imported directly via `@import` and must be available at test compile time. No hostile C double, mock allocator, or injected failure is used; all tests exercise the production implementation with `std.testing.allocator` (a leak-detecting wrapper around the GPA) and inline test data.

The tests are self-contained: fixture data is declared as string literals or inline node arrays inside each `test` block. No file I/O is performed by any `wikilink.zig` test.

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| --- | --- | --- | --- | --- | --- |
| `scanWikiLinks basic and fence skip` | test | Verifies scanner collects two hits from a body with a backtick-fenced block containing a suppressed link | Body with two wiki-links and a `` ``` `` fence | 2 hits; correct entity_id, null label on first, non-null label on second | Fence suppression; basic scan |
| `scanWikiLinks skips tilde fences` | test | Verifies tilde fences (~~~) suppress links inside them | Body with two live links flanking a ~~~ fence | 2 hits (`guides/a`, `guides/b`); fenced link absent | Tilde fence variant |
| `scanWikiLinks fragment and label` | test | Fragment (`#`) and label (`|`) parsing | Body with two fragment+label combinations | Correct fragment and label slices on both hits | Fragment/label scanner |
| `scanWikiLinks empty fragment is syntax` | test | `&#91;&#91;entity#&#93;&#93;` must be `ReferenceSyntax` | Body `"bad &#91;&#91;guides/a#&#93;&#93;"` | `error.ReferenceSyntax` | Empty-fragment rejection |
| `scanWikiLinks syntax FailInfo` | test | `&#91;&#91;#only-hash&#93;&#93;` (empty entity ID) sets FailInfo | Body `"bad &#91;&#91;#only-hash&#93;&#93;"` with `&fail` | `error.ReferenceSyntax`; `fail.line == 1`; `fail.locus() == "page.md"` | FailInfo population on empty-id syntax |
| `rewriteWikiLinks relative href` | test | End-to-end rewrite produces a relative Markdown link | Body with `&#91;&#91;guides/overview&#93;&#93;`; two nodes; `current_output_path = "getting-started.html"` | Output contains `[Content Model](guides/overview.html)`; no `&#91;&#91;` remains | Node resolution; title-as-label; relative href |
| `rewriteWikiLinks with validated fragment` | test | Fragment link is rewritten correctly with a populated `HeadingIndex` | `HeadingIndex` with `"section-one"` for `guides/overview`; `validate_fragments = true` | Output contains `[Content Model](guides/overview.html#section-one)` | Fragment validation + encoding |
| `rewriteWikiLinks missing fragment fails loud` | test | Unknown fragment on an existing page → `ReferenceMissing` with detail containing the fragment | `HeadingIndex` with `"section-one"` only; body has `#nope` | `error.ReferenceMissing`; `fail.detail()` contains `"nope"` | Fragment membership check; FailInfo detail |
| `rewriteWikiLinks fail-closed without heading index` | test | `validate_fragments = true`, `heading_index = null` → fails closed | Default opts (validate=true, index=null) | `error.ReferenceMissing`; `fail.detail()` contains `#` | Fail-closed fragment path |
| `rewriteWikiLinks bootstrap mode emits fragment without validation` | test | `validate_fragments = false` allows any fragment | `heading_index = null`; `validate_fragments = false` | Output contains `guides/overview.html#anything`; no error | Bootstrap mode |
| `scanWikiLinks fragment inside fence is skipped` | test | Fragment links inside fences suppressed | Body with one live fragment link and one fenced | 1 hit; `fragment == "live"` | Fence + fragment combination |
| `HeadingIndex lookup distinguishes unknown entity from unknown fragment` | test | `Lookup` enum correctness | Index with `"p"` → `{"sec"}`; lookups for ok/unknown-frag/unknown-entity | Correct enum variants for each case | `HeadingIndex.lookup` discriminant |
| `plan path reports missing entity, not missing heading, for &#91;&#91;typo#frag&#93;&#93;` | test | `unknown_entity` code path emits entity-only detail (no `#`) | Index has `guides/overview`; body links `guides/typo#section-one` | `error.ReferenceMissing`; `fail.detail() == "guides/typo"`; no `#` in detail | Entity-vs-fragment error routing |
| `plan path still reports missing heading on an existing page` | test | `unknown_fragment` code path emits `entity#frag` detail | Index has `guides/overview` with `"section-one"`; body links `guides/overview#nope` | `error.ReferenceMissing`; `fail.detail()` contains `#` | Fragment-missing detail includes `#` |
| `HeadingIndex duplicate ids are set membership` | test | `has` and `putOwned` with a two-entry slice | `putOwned("p", {"dup", "other"})` | `has` returns true for both; false for missing; false for unknown entity | `HeadingIndex.has` membership semantics |
| `rewriteWikiLinks missing target with FailInfo` | test | No matching node → `ReferenceMissing` with entity ID in detail | Empty nodes slice; body has `&#91;&#91;missing/page&#93;&#93;` | `error.ReferenceMissing`; `fail.detail() == "missing/page"`; `fail.line == 1` | Missing-node diagnostic path |
| `encodeFragment leaves unreserved plain` | test | RFC 3986 unreserved characters are not percent-encoded; `/` is encoded | `"section-one"` → unchanged; `"has/slash"` → `"has%2Fslash"` | Correct encoded strings | `encodeFragment` RFC 3986 contract |
| `makeDiagnostic maps ReferenceMissing` | test | `makeDiagnostic` produces a `Diagnostic` with correct code, path, and formatted line | `fail.set(2, 4, "missing/id", "")`; `error.ReferenceMissing`; `source_path = "a.md"` | `d.code == .EREFERENCEMISSING`; formatted line contains `"EREFERENCEMISSING"` and `"a.md:2:4"` | Diagnostic code mapping; `formatText` integration |
| `makeDiagnostic maps missing heading fragment` | test | Detail with `#` routes to `"heading target"` message branch | `fail.set(1, 1, "guides/a#missing", "")` | `d.message` contains `"heading target"` | `messageFor` branch selection |
| `referenceMaterialMulti unions page and include bodies` | test | Multi-body material contains IDs from all bodies; single-body does not | Two bodies (`&#91;&#91;alpha&#93;&#93;` and `&#91;&#91;beta&#93;&#93;`); two-node graph | Multi: both `alpha` and `beta` in material; single: only `alpha` | `referenceMaterialMulti` union; `referenceMaterial` scope |
| `referenceMaterialMulti missing target keeps include locus` | test | Missing target in include body sets `fail.locus()` to the include body's path | `body_paths` `["alpha.md", "includes/blurb.md"]`; bad ref in second body | `fail.detail() == "missing/id"`; `fail.locus() == "includes/blurb.md"`; `fail.line == 2` | Multi-body locus propagation |

## Case-by-case walkthrough

### Empty entity ID before `#`

**Injected behavior:**
The body `"bad &#91;&#91;#only-hash&#93;&#93;"` contains a `&#91;&#91;` followed immediately by `#`, so the entity-ID character scan collects zero bytes before a non-ID character.

**Wrapper boundary exercised:**
`scanWikiLinks` at the post-`&#91;&#91;` entity-ID accumulation loop. The check `if (i == id_start)` detects a zero-length entity ID and calls `setFail` followed by `return error.ReferenceSyntax`.

**Expected response:**
`error.ReferenceSyntax`; `FailInfo.line == 1`; `FailInfo.locus() == "page.md"`. No `WikiHit` is appended.

**Forbidden unsafe response:**
Constructing a zero-length `entity_id` slice and passing it to `identity.validateEntityId` (which might accept or reject it depending on its own contract), or appending a `WikiHit` with an empty entity ID.

**Evidence strength:** Directly demonstrated.

**Residual gap:**
The test checks `fail.line` and `fail.locus()` but not `fail.column`. Column accuracy for this position is not directly asserted.

***

### Empty fragment `&#91;&#91;entity#&#93;&#93;`

**Injected behavior:**
Body `"bad &#91;&#91;guides/a#&#93;&#93;"` — a valid entity ID is followed by `#` and then immediately `]]`.

**Wrapper boundary exercised:**
`scanWikiLinks` fragment accumulation loop: after advancing past `#`, the `if (i == frag_start)` guard detects a zero-length fragment and returns `error.ReferenceSyntax`.

**Expected response:**
`error.ReferenceSyntax` with `FailInfo` populated.

**Forbidden unsafe response:**
Recording a `WikiHit` with `fragment = ""` (empty slice) and forwarding that to `checkFragment`.

**Evidence strength:** Directly demonstrated.

**Residual gap:**
The `&#91;&#91;entity#|label&#93;&#93;` variant (empty fragment with a label) is named as a reachable code comment but the exact test for that variant is the empty-fragment test above; no separate test covers `&#91;&#91;entity#|label&#93;&#93;` specifically.

***

### Missing entity in the page graph

**Injected behavior:**
Body `"See &#91;&#91;missing/page&#93;&#93; here"` with an empty `nodes` slice. No node with id `"missing/page"` exists.

**Wrapper boundary exercised:**
`rewriteWikiLinksOpts` after building the `node_map`: `findNodeMap` returns null; the `orelse` branch fills `FailInfo` and returns `error.ReferenceMissing`.

**Expected response:**
`error.ReferenceMissing`; `fail.detail() == "missing/page"`; `fail.line == 1`.

**Forbidden unsafe response:**
Attempting to dereference a null node pointer, or constructing a href from an absent node's (undefined) `id` field.

**Evidence strength:** Directly demonstrated.

**Residual gap:**
Only a single missing node is tested. The behavior when some nodes are present and one is missing is not separately tested, though the code path is the same.

***

### Fragment on entity absent from `HeadingIndex` (unknown entity vs. unknown fragment)

**Injected behavior:**
`&#91;&#91;guides/typo#section-one&#93;&#93;` where `guides/typo` does not exist in the `HeadingIndex` (which contains `guides/overview`). The entity `guides/typo` also does not exist in the frozen `nodes`.

**Wrapper boundary exercised:**
`checkFragment` calls `idx.lookup("guides/typo", "section-one")` → `.unknown_entity`. The `.unknown_entity` branch fills `FailInfo.detail` with `entity_id` only (no `#`), then returns `error.ReferenceMissing`.

**Expected response:**
`error.ReferenceMissing`; `fail.detail() == "guides/typo"` (no `#`). The `messageFor` function will produce the page-graph message (`"wiki-link target \"guides/typo\" not found in the page graph"`) rather than a heading-not-found message.

**Forbidden unsafe response:**
Reporting a missing-heading diagnostic for a page that was never present, which would mislead the author into searching for a heading on a non-existent page.

**Evidence strength:** Directly demonstrated.

**Residual gap:**
In this test, `guides/typo` is absent from both the `HeadingIndex` and the `nodes` slice. The case where a typo entity exists in `nodes` but was never added to the `HeadingIndex` (e.g., a page that was never rendered) is not independently tested.

***

### Fragment on existing entity but unknown heading

**Injected behavior:**
`&#91;&#91;guides/overview#nope&#93;&#93;` where `guides/overview` is in the `HeadingIndex` with heading `"section-one"` only.

**Wrapper boundary exercised:**
`checkFragment` → `idx.lookup("guides/overview", "nope")` → `.unknown_fragment`. `failFragmentDetail` writes `"guides/overview#nope"` into `FailInfo` detail.

**Expected response:**
`error.ReferenceMissing`; `fail.detail()` contains `#`. `messageFor` produces `"wiki-link heading target \"guides/overview#nope\" not found on the page"`.

**Forbidden unsafe response:**
Emitting the entity-only message, or silently emitting a broken anchor in the output.

**Evidence strength:** Directly demonstrated.

**Residual gap:**
The test calls `referenceMaterialMulti`; the `rewriteWikiLinksOpts` path for the same fragment-on-existing-page case is covered by a different test (`rewriteWikiLinks missing fragment fails loud`).

***

### Fail-closed when `validate_fragments = true` and no `HeadingIndex`

**Injected behavior:**
`rewriteWikiLinks` is called (which uses default `ResolveOptions`: `validate_fragments = true`, `heading_index = null`) on a body with a fragment link.

**Wrapper boundary exercised:**
`checkFragment`: the `opts.heading_index orelse { …; return error.ReferenceMissing }` branch fires.

**Expected response:**
`error.ReferenceMissing`; `fail.detail()` contains `#`.

**Forbidden unsafe response:**
Silently emitting the fragment without validation, which would produce a link to a potentially non-existent anchor.

**Evidence strength:** Directly demonstrated.

**Residual gap:**
Only the null-index path is tested here. The interaction with a present but empty `HeadingIndex` (all entities, no headings) is not separately tested.

***

### Bootstrap mode: fragment emitted without validation

**Injected behavior:**
`rewriteWikiLinksOpts` with `validate_fragments = false` and `heading_index = null` on a body with `&#91;&#91;guides/overview#anything&#93;&#93;`.

**Wrapper boundary exercised:**
`checkFragment` returns at the top-level `if (!opts.validate_fragments) return;` guard.

**Expected response:**
A successful rewrite; output contains `guides/overview.html#anything`. No error.

**Forbidden unsafe response:**
Failing with `ReferenceMissing` in bootstrap mode, which would prevent the first-pass render needed to populate the `HeadingIndex`.

**Evidence strength:** Directly demonstrated.

**Residual gap:**
The bootstrap mode only bypasses `checkFragment`. The node-resolution step still requires the entity to exist in `nodes`. A test where the entity itself is missing in bootstrap mode is not present.

***

### `referenceMaterialMulti` locus propagation through include bodies

**Injected behavior:**
Two bodies are provided: a page body with no wiki-links, and an include-fragment body (`"Line1\nSee &#91;&#91;missing/id&#93;&#93; please."`) at `"includes/blurb.md"` that references a nonexistent entity. `body_paths` is set to `["alpha.md", "includes/blurb.md"]`.

**Wrapper boundary exercised:**
`collectIdsFromBody` is called for each body with the corresponding path as `body_path`. When the missing entity is not found in `materialFromIdLocs`, `FailInfo.locus` is set to `"includes/blurb.md"` and `FailInfo.line` to `2`.

**Expected response:**
`error.ReferenceMissing`; `fail.detail() == "missing/id"`; `fail.locus() == "includes/blurb.md"`; `fail.line == 2`.

**Forbidden unsafe response:**
Reporting the top-level page path (`"alpha.md"`) as the source of the diagnostic instead of the include body where the bad link actually resides.

**Evidence strength:** Directly demonstrated.

**Residual gap:**
Only a single-level include body is tested. Deeper include nesting is handled by `src/include.zig`'s `FailInfo` propagation; the wikilink module itself does not recurse into include bodies — it receives pre-expanded or separately-provided body slices from the caller.

***

### `encodeFragment` percent-encoding

**Injected behavior:**
Two fragment strings are passed to `encodeFragment`: `"section-one"` (all RFC 3986 unreserved characters) and `"has/slash"` (contains `/`, a reserved character).

**Wrapper boundary exercised:**
`encodeFragment` per-byte encoding loop; the `unreserved` predicate; `hexNibble` upper-nybble and lower-nybble computation.

**Expected response:**
`"section-one"` → `"section-one"` (unchanged); `"has/slash"` → `"has%2Fslash"`.

**Forbidden unsafe response:**
Encoding unreserved characters (breaking cosmetically valid URLs), or not encoding reserved characters (producing broken anchor links).

**Evidence strength:** Directly demonstrated.

**Residual gap:**
The test covers only ASCII. Multi-byte UTF-8 codepoints (which would be percent-encoded byte-by-byte) are not tested. The `@intCast(c >> 4)` and `@intCast(c & 0xf)` casts assume `c` is a `u8`; this is structurally enforced by the loop type but not covered by a boundary test for the byte value `0xFF`.

***

## Control flow

### `scanWikiLinks`

```text
scanWikiLinks(body, allocator, out, fail_out, locus_path)
    loop i over body bytes
        ├── if atLineStart(body, i)
        │       if fenceAtLineStart → toggle fence_ch/fence_run state; advance to line end; continue
        ├── if fence_ch != 0 → i += 1; continue   [inside fence: skip]
        └── if body[i..i+2] == "[[" and i+3 <= len
                scan entity ID chars (isEntityIdChar)
                    ├── zero-length id → setFail; return ReferenceSyntax
                    └── validateEntityId(entity_id)
                            ├── invalid → setFail; return ReferenceSyntax
                            └── valid
                if '#' → scan fragment bytes
                    ├── newline/CR/bare ']' → setFail; return ReferenceSyntax
                    └── frag_start == frag_end → setFail; return ReferenceSyntax
                if '|' → scan label bytes
                    ├── newline/CR → setFail; return ReferenceSyntax
                    └── lab_start == lab_end → setFail; return ReferenceSyntax
                if body[i..i+2] != "]]" → setFail; return ReferenceSyntax
                lineColAt(body, start) → line, column
                out.append(WikiHit{…})
```


### `rewriteWikiLinksOpts`

```text
rewriteWikiLinksOpts(allocator, body, nodes, current_output_path, fail_out, opts)
    scanWikiLinks → hits
    if hits empty → return dupe(body)
    buildNodeMap(allocator, nodes) → node_map
    loop over hits
        ├── findNodeMap(node_map, hit.entity_id)
        │       orelse → setFail; return ReferenceMissing
        ├── if hit.fragment → checkFragment(opts, entity_id, frag, …)
        │       ├── validate_fragments=false → return immediately
        │       ├── heading_index null → setFail; return ReferenceMissing
        │       └── idx.lookup(entity_id, frag)
        │               ├── .ok → continue
        │               ├── .unknown_fragment → failFragmentDetail; return ReferenceMissing
        │               └── .unknown_entity → f.set(…, entity_id, locus); return ReferenceMissing
        ├── appendSlice(body[copy_from..hit.offset])
        ├── htmlOutputPath → to_out (or PathError)
        ├── relativeHref(current_output_path, to_out) → href (or PathError)
        ├── escapeMdLabel(label or node.title or node.id) → label
        ├── append "[label](href[#enc_frag])"
        └── copy_from = hit.end
    appendSlice(body[copy_from..])
    return out.toOwnedSlice
```


### `referenceMaterialMulti`

```text
referenceMaterialMulti(allocator, bodies, body_paths, nodes, fail_out, opts)
    validate body_paths.len == bodies.len (or PathError)
    for each body[i] with path[i]
        collectIdsFromBody(body, path, allocator, locs, seen, fail_out, opts)
            scanWikiLinks → hits
            for each hit
                checkFragment (if fragment present)
                appendUniqueIdLocHashed(locs, seen, IdLoc{id, line, col, locus, fragment})
    materialFromIdLocs(allocator, locs.items, nodes, fail_out)
        sort locs by id (lexicographic, on copy)
        buildNodeMap(nodes)
        for each sorted loc
            findNodeMap(loc.id) orelse → setFail; return ReferenceMissing
            htmlOutputPath(node.id) orelse → setFail; return PathError
            append "id\0out_path\0title\0"
        return toOwnedSlice
```
