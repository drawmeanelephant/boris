---
title: "`src/layout_select.zig` surface and execution"
id: docs/boris/src/layout_select/surface-and-execution
parent: docs/boris/src/layout_select
status: draft
tags: [boris, zig, source-reference, surface, layout_select]
---

# `src/layout_select.zig` surface and execution

## Threat model

The file is designed to make the following classes of adversarial or erroneous input fail loudly at the earliest possible API boundary rather than producing silent misbehavior at render time.

**Filesystem traversal via layout paths.** A `layout_path` value like `../../themes/beta/layouts/main.html` or `/abs/main.html` must be rejected before it is ever opened. `validateLayoutPath` performs a purely lexical check: it rejects empty strings, leading `/` or `\`, Windows drive letters (`C:`), trailing slashes, backslashes anywhere, and `.` or `..` segments. This check is exercised at parse time in `cli.parseOptions` and again at preflight in `compile.compileHtmlSite`. The hostile test H5 directly confirms that a `..`-containing path in a `--layout-rule` produces `error.InvalidLayoutPath` at every surface (pure call, CLI parse, and library compile) without writing any HTML.

**Ambiguous glob matches of equal specificity.** Two glob rules matching the same entity id with the same number of literal segments produce `error.AmbiguousGlob` rather than a silently arbitrary selection. Specificity is measured by `globLiteralCount`—the number of non-`*` segments—so `reference/*` (1 literal) beats `*/*` (0 literals), but `reference/*` and `*/configuration` (each 1 literal) are ambiguous. Equal layout paths do not resolve the ambiguity. The hostile test H2 directly demonstrates this both in the pure call and in a full HTML compile where no output HTML is written.

**Partial-wildcard and double-star glob patterns.** The grammar intentionally rejects `ref*`, `**`, and any segment containing a bare `*` that is not the complete segment. `validateGlobPattern` enforces this per-character for literal segments. This is tested in both the in-file `parseSelector closed grammar` test and H5's invalid-selector CLI test.

**Declaration-order-dependent selection or digests.** A rule table presented in a different argv order must produce identical layout selections for every page and an identical digest string. `selectLayout` scans for exact-id matches independently of order, resolves glob ambiguity by specificity score rather than first-match, and uses role name lookup rather than index position. `ruleTableDigestMaterial` sorts a copy of the rule slice via `sortRulesCanonical` before serializing. Both properties are directly demonstrated in the in-file tests `rule order does not affect selection` and `ruleTableDigestMaterial ignores declaration order`, and in the hostile test H3 which additionally verifies byte-identical HTML trees across three permutations.

**Duplicate selectors within a target.** Two rules with the same `(kind, value)` pair but different layout paths would create ambiguity at the `id` or `role` tier. `rejectDuplicateSelectors` performs an O(n²) pairwise scan and returns `error.DuplicateSelector`. Selector equality is byte-exact and kind-sensitive: an `id:index` rule and a `role:trunk` rule with the same value string are not duplicates. The in-file test `rejectDuplicateSelectors independent of path equality` confirms duplicates are detected even when layout paths are identical. `selectLayout` includes a secondary duplicate-id guard inline.

**Rule table overflow.** More than `max_rules_per_target` (256) rules in a single call to `rejectDuplicateSelectors` returns `error.RuleLimitExceeded`. This is declared but its test coverage in the inspected test files is not directly demonstrated—only the declaration exists in production code.

**Silent fallback past a missing layout file.** A layout path that passes lexical validation but does not exist on disk must not cause the pipeline to silently fall through to the next matching rule. The hostile test H5 `missing layout file fails without silent next-rule fallback` confirms that a compile with an exact-id rule pointing to a nonexistent file returns an error (class is I/O or layout-load, exact type not verified here) and that no HTML is written. This is not enforced by `layout_select.zig` itself—it is an I/O-time property of the compiler—but `selectLayout` reports the resolved path so the compiler can fail on open.

**Mixed theme roots across fallback and rules.** Layout paths from different theme directories being mixed in one target is checked by `target.zig`'s `rejectMixedThemeRoots` function, not by this file. `layout_select.zig` is unaware of theme roots. The hostile test H5 tests that property against `target_mod.rejectMixedThemeRoots`.

**Untested in this file:** `RuleLimitExceeded` trigger (no test with 257 rules found), Unicode in glob segments beyond ASCII whitespace rejection, interaction between `collectDeclaredLayouts` deduplication and empty rule tables, and behavior of `writeSelector` when the entity-id value is near `max_entity_id_bytes` relative to the stack buffer size used in `ruleTableDigestMaterial`.

## Allocator and ownership notes

`layout_select.zig` allocates in two public functions. `collectDeclaredLayouts` takes a `gpa: std.mem.Allocator`, grows an `ArrayList`, and returns `[]const []const u8` via `toOwnedSlice`; the caller owns the slice spine but not the pointed-to path bytes (which are views into the caller-supplied `fallback` and `rules` strings). `ruleTableDigestMaterial` takes a `gpa`, allocates a temporary sorted copy of the rules (freed with `defer`), grows a `buf: ArrayList(u8)`, and returns `[]u8` via `toOwnedSlice`; the caller owns and must free the returned bytes. All other public functions are allocation-free: they operate on caller-supplied slices and stack buffers only. `writeSelector` writes into a caller-supplied `buf: []u8` stack buffer; the maximum output length is bounded by `identity.max_entity_id_bytes + 16`, and `ruleTableDigestMaterial` uses a `[identity.max_entity_id_bytes + 16]u8` stack array for this purpose.

The `errdefer list.deinit(gpa)` and `errdefer buf.deinit(gpa)` patterns in both allocating functions ensure no leak on error paths. No arena is used internally; callers that want arena-backed results must supply an arena allocator as `gpa`.
