---
title: "`src/cache.zig` evidence and cases"
id: docs/boris/src/cache/evidence-and-cases
parent: docs/boris/src/cache
status: draft
tags: [boris, zig, source-reference, evidence, cache]
---

# `src/cache.zig` evidence and cases

## Test suite

### Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `"Same inputs produce the same key across runs"` | test | Determinism of `computePageFingerprint` | Two identical calls | `key1 == key2` byte-for-byte | Fingerprint is deterministic |
| `"input adapter identity invalidates only explicit adapted fingerprints"` | test | Extension-layer backward compatibility | Legacy call, empty-input call, and textile-v1 call | Legacy == empty; legacy ≠ textile-v1 | Empty `input_material` is a digest no-op; non-empty changes digest |
| `"fingerprint length prefixes are little-endian fixed"` | test | Smoke: non-empty inputs are stable | Two identical calls with non-trivial inputs | `key == key2` | Determinism; encoding is fixed |
| `"output digest helpers are deterministic and content-sensitive"` | test | `hashBytes` and `hexDigest` | `"hello"` twice; `"hallo"` once | Same input → same digest; different input → different digest; hex length is 64 | Content-addressed freshness |
| `"Source change changes only that page's key"` | test | Content-sensitivity of `computePageFingerprint` | Modified `source_bytes`; different `entity_id` | Both comparisons produce unequal fingerprints | Source and identity inputs are reflected in digest |
| `"Target configuration changes isolate page keys"` | test | `target_name` and `layout_path` sensitivity | Different `target_name` values; different `layout_path` | Unequal fingerprints in both cases | Target configuration is a fingerprint input |
| `"theme material changes page fingerprint when present"` | test | Theme extension backward compatibility | Base call (no theme), themed call, original 7-param call | Base == same_empty; base ≠ with_theme | Empty theme material is a digest no-op; non-empty theme changes digest |
| `"Affected pages query scenarios"` | test | `getAffectedPages` correctness across five sub-cases | Three nodes; `DependencyIndex` with layout, include, transitive include, and page→page reference deps | Direct page source change → 1 page; reference target edit → 2 pages (referrer + target); transitive include → 2 pages; layout → 2 pages; isolated layout → 1 page | Reverse dependency walk; page→page reference propagation; include transitive chains |
| `"Output ordering is stable"` | test | Lexicographic sort of `getAffectedPages` result | Three nodes with IDs `"z"`, `"a"`, `"m"` sharing one layout | Result is `["a", "m", "z"]` | Output ordering is deterministic regardless of hash-map iteration order |

### Hostile-case walkthrough

The tests in this file are correctness tests, not hostile ABI tests. There is no C boundary, no hostile double, and no adversarial allocator in use. The following subsections describe the meaningful boundary cases the tests exercise.

***

### `"Source change changes only that page's key"`

**Injected behavior:**
`source_bytes` is changed from `"source data"` to `"modified source"` while all other inputs remain constant. A second variant changes only `entity_id`.

**Wrapper boundary exercised:**
The SHA-256 update in step 5 (source bytes, length-prefixed).

**Expected response:**
Both comparisons return unequal digests. The fingerprint is sensitive to source content and to entity identity independently.

**Forbidden unsafe response:**
Returning equal fingerprints when source bytes differ, which would suppress a required re-render.

**Evidence strength:**
Directly demonstrated.

**Residual gap:**
Does not test near-collision inputs (e.g., a one-byte edit deep in a large document). Does not test empty `source_bytes` vs `source_bytes = "\x00"`.

***

### `"input adapter identity invalidates only explicit adapted fingerprints"`

**Injected behavior:**
Compares: (a) `computePageFingerprintTheme` with all-empty optional fields; (b) `computePageFingerprintThemeInput` with `input_material = ""`; (c) same but with `input_material = "boris-textile-adapter-v1"`.

**Wrapper boundary exercised:**
The `if (input_material.len > 0)` branch in `computePageFingerprintThemeInput`, and the delegation chain from `computePageFingerprintTheme` to `computePageFingerprintThemeInput`.

**Expected response:**
(a) == (b) byte-for-byte. (a) ≠ (c).

**Forbidden unsafe response:**
(a) ≠ (b) would break backward compatibility for all existing Markdown-mode caches. (a) == (c) would mean Textile-mode pages silently reuse Markdown-mode cache entries.

**Evidence strength:**
Directly demonstrated.

**Residual gap:**
Does not test that two different non-empty `input_material` values produce distinct digests (implied by SHA-256 properties but not explicitly asserted). Does not test the separator sentinel `"boris-input-adapter\x00"` independently against a crafted collision with a theme_material string that starts with the same bytes.

***

### `"Affected pages query scenarios"` — reference-target edit sub-case

**Injected behavior:**
`DependencyIndex` is set up so `guides/intro` has a `.reference` dependency on `guides/outro`. `getAffectedPages` is called with `changed_path = "content/guides/outro.md"`.

**Wrapper boundary exercised:**
The page→page reverse-walk path in `getAffectedPages` — specifically, when a page node is found, its reverse dependents in `dep_index.reverse` are also pushed onto the stack, allowing a referrer to be dirtied when its reference target changes.

**Expected response:**
`affected.len == 2`; result is `["guides/intro", "guides/outro"]` in that order.

**Forbidden unsafe response:**
Returning only `["guides/outro"]` would miss a page that embeds or depends on the changed page's content, causing a stale render to persist.

**Evidence strength:**
Directly demonstrated.

**Residual gap:**
Does not test cycles in the dependency graph (which should not exist after validation, but `getAffectedPages` has no cycle guard; a cyclic `DependencyIndex` would cause infinite iteration). Does not test the dual-key reverse lookup when entity ID and source path are identical strings.

***

### `"Affected pages query scenarios"` — transitive include sub-case

**Injected behavior:**
`includes/sidebar.html` declares a dependency on `includes/widget.html`. Both `guides/intro` and `guides/outro` depend on `includes/sidebar.html`. `getAffectedPages` is called with `"includes/widget.html"`.

**Wrapper boundary exercised:**
The non-page branch of `getAffectedPages`: `includes/widget.html` matches no node, so only its reverse dependents are pushed. `includes/sidebar.html` is pushed, also matches no node, and its reverse dependents (`guides/intro`, `guides/outro`) are pushed and ultimately resolved as page nodes.

**Expected response:**
`affected.len == 2`; result is `["guides/intro", "guides/outro"]`.

**Forbidden unsafe response:**
Returning an empty or incomplete set would cause transitive include dependents to be served stale.

**Evidence strength:**
Directly demonstrated.

**Residual gap:**
Does not test a three-level transitive chain (non-page → non-page → non-page → page). Does not test a path that appears in `dep_index.reverse` but has no corresponding node.

***

### `"Output ordering is stable"`

**Injected behavior:**
Three page nodes with IDs intentionally in non-alphabetical insertion order (`"z"`, `"a"`, `"m"`) all share one layout dependency.

**Wrapper boundary exercised:**
The `std.mem.sort` call on the final `list.items` before `toOwnedSlice`.

**Expected response:**
Result slice is `["a", "m", "z"]` regardless of hash-map iteration order.

**Forbidden unsafe response:**
A non-deterministic or hash-map-order-dependent return value would make incremental builds non-reproducible across runs.

**Evidence strength:**
Directly demonstrated.

**Residual gap:**
The test does not verify that the sort is stable in the presence of duplicate IDs (which `DependencyIndex` and the node scan should prevent, but `getAffectedPages` does not independently guard). Does not test with an empty node set where `dep_index.reverse` has entries.

## Control flow

### Fingerprinting

```text
caller
    → computePageFingerprint(7 params)
        → computePageFingerprintTheme(+ theme_material = "")
            → computePageFingerprintThemeInput(+ input_material = "")
                → Sha256.init
                → hasher.update(CACHE_FORMAT_VERSION)
                → updateLen + hasher.update(target_name)
                → updateLen + hasher.update(layout_path)
                → updateLen + hasher.update(entity_id)
                → updateLen + hasher.update(source_bytes)
                → for each include_dep: updateLen + hasher.update(inc_bytes)
                → updateLen + hasher.update(layout_bytes)
                → [if non-empty] updateLen + hasher.update(site_nav_material)
                → [if non-empty] updateLen + hasher.update(theme_material)
                → [if non-empty] hasher.update("boris-input-adapter\x00")
                              + updateLen + hasher.update(input_material)
                → hasher.final(&digest)
                → return digest [^1_32]u8
```

All computation is stack-local. No heap allocation occurs.

### `getAffectedPages`

```text
caller: getAffectedPages(allocator, changed_path, nodes, dep_index)
    → allocate affected_ids (StringHashMap), visited (StringHashMap), stack (ArrayList)
    → stack.append(changed_path)
    → loop while stack not empty:
        → curr = stack.pop()
        → if visited: continue
        → visited.put(curr)
        → linear scan of nodes for curr (by .id or .source_path)
        → if page found:
            → affected_ids.put(page_id)
            → push reverse dependents keyed by page_id
            → if page_id != curr: push reverse dependents keyed by curr (source-path form)
        → else (non-page asset):
            → push reverse dependents keyed by curr
    → collect affected_ids keys into list, dupe each string
    → std.mem.sort(list.items) lexicographically
    → return list.toOwnedSlice (caller owns all strings + slice)
```

Error paths: any allocation failure in the loop propagates as an error return. The `errdefer` block frees all duped strings and the list if an error occurs after partial allocation. `visited` and `affected_ids` are deferred-deinit inside the function; `stack` is deferred-deinit; the caller receives only the sorted owned slice.
