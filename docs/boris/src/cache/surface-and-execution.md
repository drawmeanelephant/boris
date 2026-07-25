---
title: "`src/cache.zig` surface and execution"
id: docs/boris/src/cache/surface-and-execution
parent: docs/boris/src/cache
status: draft
tags: [boris, zig, source-reference, surface, cache]
---

# `src/cache.zig` surface and execution

## Fingerprint API design

### Format version sentinel

```zig
pub const CACHE_FORMAT_VERSION = "boris-cache-v2-layout-rules";
```

This string is the first bytes hashed in every fingerprint. Its purpose is to force a global cache invalidation when the fingerprint input set or interpretation changes. The comment specifies that it must be bumped whenever "fingerprint inputs or manifest discriminator semantics change." It was last updated to include `layout-rules`, meaning the effective selected layout per page is now a factor in the fingerprint. Older manifests computed without this version string will compare unequal to manifests computed with it, triggering a cold rebuild. This is behavior documented in the source comment; whether the pipeline that reads the manifest actually enforces a cold rebuild on version mismatch is outside the scope of this file and not confirmed here.

### Length-prefix encoding

```zig
fn updateLen(hasher: *Sha256, len: u64) void {
    var buf: [^1_8]u8 = undefined;
    std.mem.writeInt(u64, &buf, len, .little);
    hasher.update(&buf);
}
```

`updateLen` is a private helper that serializes a `u64` length as exactly 8 bytes in little-endian order before every variable-length field update. This is necessary to prevent prefix-extension collisions: without length prefixes, `hash("ab" ++ "c")` would equal `hash("a" ++ "bc")`. The choice of little-endian is fixed (`.little` is explicit), which means digests are identical on big-endian and little-endian hosts for the same input — the encoding is host-independent by construction. However, no test in this file computes a known golden vector and asserts its byte value; the test "fingerprint length prefixes are little-endian fixed" is a smoke test that demonstrates determinism across two calls on the same host, not a cross-platform equivalence proof.

### Extension chain

The three public fingerprint functions form a delegation chain:

```text
computePageFingerprint(7 params)
    → computePageFingerprintTheme(8 params, theme_material = "")
        → computePageFingerprintThemeInput(9 params, input_material = "")
            → SHA-256 computation
```

Each wrapper passes an empty string (`""`) for the parameter it does not expose. Inside `computePageFingerprintThemeInput`, optional parameters are only admitted into the hash when non-empty:

```zig
if (site_nav_material.len > 0) { ... }
if (theme_material.len > 0) { ... }
if (input_material.len > 0) { ... }
```

This means callers using the original `computePageFingerprint` signature with no site nav material produce the same digest as callers using `computePageFingerprintThemeInput` with all three optional fields set to `""`. The backward-compatibility invariant is: **empty optional material is a no-op on the digest**. This is directly demonstrated by the test `"theme material changes page fingerprint when present"` and `"input adapter identity invalidates only explicit adapted fingerprints"`.

Note that `input_material`, unlike `site_nav_material` and `theme_material`, additionally hashes a separator sentinel `"boris-input-adapter\x00"` before its length and value. This differentiates the input-material slot structurally from the theme slot, preventing cross-slot collisions if future slots are added.

### Ordered inputs to `computePageFingerprintThemeInput`

The hash is built in the following fixed order:

1. `CACHE_FORMAT_VERSION` — version sentinel (no length prefix; fixed string)
2. `target_name` length + bytes — build target identity
3. `layout_path` length + bytes — layout file path
4. `entity_id` length + bytes — page identity
5. `source_bytes` length + bytes — raw source content
6. For each element of `include_deps`: length + bytes — include dependencies **in caller-provided order**
7. `layout_bytes` length + bytes — layout file content
8. `site_nav_material` length + bytes — only if non-empty
9. `theme_material` length + bytes — only if non-empty
10. `"boris-input-adapter\x00"` + `input_material` length + bytes — only if non-empty

The include dependencies are hashed **in the order supplied by the caller** (`include_deps: []const []const u8`). The function does not sort them internally. Callers are therefore responsible for supplying includes in a stable, deterministic order — typically the order produced by `DependencyIndex.forward` after sorting, which `compareDependency` in `dependency.zig` establishes. If callers supply includes in a different order, they will compute a different fingerprint for the same logical content. This is a contract on the caller, not enforced by `cache.zig`.

## `getAffectedPages` design

```zig
pub fn getAffectedPages(
    allocator: std.mem.Allocator,
    changed_path: []const u8,
    nodes: []const graph_mod.Node,
    dep_index: *const dependency.DependencyIndex,
) ![]const []const u8
```

The function performs a reverse-dependency BFS/DFS starting from `changed_path`. It uses two `StringHashMapUnmanaged(void)` sets (`affected_ids` and `visited`) to track results and prevent revisits, and a `std.ArrayList([]const u8)` stack for iterative traversal.

**Node matching:** For each path popped from the stack, the function scans `nodes` linearly (`O(n)`) to determine whether the path corresponds to a known page entity — either by matching `node.id` or `node.source_path`. If a match is found, the node's entity ID is added to `affected_ids`. If no match is found, the path is treated as a non-page asset (layout, include, etc.) and only its reverse dependents are followed.

**Reverse walk:** The function consults `dep_index.reverse` using both the entity ID form and the source-path form of the current node (when they differ), to handle dependency edges that were registered in path form. This dual-key lookup is the mechanism by which `include/widget.html → include/sidebar.html → guides/intro` transitive chains are traversed correctly.

**Page-to-page references:** When a page is found, its reverse dependents are also followed. This means that if `guides/intro` declares a reference dependency on `guides/outro`, editing `guides/outro` will dirty `guides/intro` (because `guides/intro` appears as a reverse dependent of `guides/outro`). This behavior is directly demonstrated by the test case "Editing the reference *target* dirties the referrer."

**Ownership:** The returned `[]const []const u8` is caller-owned. Each string in the slice is a fresh `allocator.dupe` of the entity ID from the hash map. The caller must free each string individually and then free the slice itself. The `errdefer` block in the function handles partial allocation cleanup on error. The strings themselves are dupes of entity ID keys from the `DependencyIndex`; the lifetime of the original strings in the index is not relevant for the caller's slice.

**Sorting:** Results are sorted using `std.mem.sort` with a lexicographic `std.mem.order` comparator. This is deterministic for a fixed input set, but the `StringHashMapUnmanaged` iteration order (from which the pre-sort list is populated) is not guaranteed to be stable by the standard library. The sort ensures a stable output regardless of hash-map iteration order.

## Ownership and allocation summary

| Function | Allocates | Returns | Caller responsibility |
| :-- | :-- | :-- | :-- |
| `computePageFingerprint` | No | `[^1_32]u8` (stack) | None |
| `computePageFingerprintTheme` | No | `[^1_32]u8` (stack) | None |
| `computePageFingerprintThemeInput` | No | `[^1_32]u8` (stack) | None |
| `hashBytes` | No | `[^1_32]u8` (stack) | None |
| `hexDigest` | No | `[^1_64]u8` (stack) | None |
| `getAffectedPages` | Yes (via `allocator`) | `[]const []const u8` heap | Free each string; free slice |
