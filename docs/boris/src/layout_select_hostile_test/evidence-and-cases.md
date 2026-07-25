---
title: "`src/layout_select_hostile_test.zig` evidence and cases"
id: docs/boris/src/layout_select_hostile_test/evidence-and-cases
parent: docs/boris/src/layout_select_hostile_test
status: draft
tags: [boris, zig, source-reference, evidence, layout_select_hostile_test]
---

# `src/layout_select_hostile_test.zig` evidence and cases

## Test harness construction

The root module for the hostile layout test binary is `src/layout_select_hostile_test.zig`, created in `build.zig` as `layout_hostile_mod`:

```zig
const layout_hostile_mod = b.createModule(.{
    .root_source_file = b.path("src/layout_select_hostile_test.zig"),
    .target = target,
    .optimize = optimize,
});
linkApex(layout_hostile_mod, b, false);
layout_hostile_mod.addOptions("build_options", apex_opts);
```

`linkApex(..., false)` compiles `vendor/apex/apex.c` (the real host adapter) and links the static ApexMarkdown archives. `apex_opts` adds `build_options` with `hostile_apex = false`. The module is added to `apex_needing`, so `ensure_apex.step` (the CMake build script) must complete before this test binary is compiled. The production binary is never affected.

The module imports four product source files directly by relative path:

```zig
const layout_select = @import("layout_select.zig");
const compile      = @import("compile.zig");
const target_mod   = @import("target.zig");
const page_mod     = @import("page.zig");
const cli          = @import("cli.zig");
```

No named module imports (e.g. `@import("apex")`) are present in this file — unlike `apex_hostile_test.zig`, which receives `apex` as an injected named module. This means `layout_select_hostile_test.zig` reaches the real Apex engine only transitively, through `compile.zig` and `aside.zig`, which themselves import `apex.zig`.

The fixture tree is at `docs/contracts/fixtures/layout-rules/hostile/`. The harness resolves fixture paths via compile-time constants:

```zig
const fixture_root   = "docs/contracts/fixtures/layout-rules/hostile";
const content_root   = fixture_root ++ "/content";
const theme_alpha    = fixture_root ++ "/themes/alpha";
const theme_beta     = fixture_root ++ "/themes/beta";
const layout_main    = theme_alpha ++ "/layouts/main.html";
// ...
```

These are relative paths; the test runner is set to `cwd = b.path(".")` (the repository root), so they resolve against the workspace root at runtime.

Each test that requires I/O creates a disposable `WorkDir` under `test-output/layout-hostile-{label}-{random4hex}/` and calls `cleanup()` via `defer`. The `WorkDir` helper encapsulates `createDirPath`, `writeFile`, `readFile`, `fileExists`, and `deleteTree` via the `std.Io` abstraction. Random suffix bytes are sourced from `io.random(&rnd)`.

The step name `test-layout-hostile` is declared in `build.zig` and is also included in the default `test` step:

```zig
test_step.dependOn(&run_layout_hostile_tests.step);
```

So the layout hostile tests run on every `zig build test` invocation. The opt-in `zig build test-layout-hostile` is an alias for the same step without running unrelated tests.

There is no mechanism by which the hostile Apex double (`apex_hostile.c`) can be accidentally linked into this module. The `hostile_opts` (`hostile_apex = true`) and `apex_hostile_lib_mod` are used only for `apex_hostile_root` / `apex_hostile_tests`. The build graph is strictly partitioned.

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `standardRules()` | Helper function | Builds a canonical 3-rule set (id:index→home, glob:reference/*→ref, role:trunk→section) for reuse across multiple tests | None | `[^1_3]LayoutRule` | — |
| `compileWithRules(...)` | Helper function | Calls `compile.compileHtmlSite` with a caller-supplied rule slice and fallback; wraps dist, incremental, quiet | io, gpa, dist path, rules, fallback, incremental flag | `compile.CompileStats` or error | `compile.CompileStats` ownership and error propagation |
| `markerOf(html)` | Helper function | Extracts the `data-layout="..."` attribute value from HTML output | HTML string | Optional slice into HTML | Layout marker is present and correctly written by templates |
| `expectMarker(html, want)` | Helper function | Asserts `markerOf` returns the given string; prints a diagnostic and returns `error.TestExpectedEqual` on failure | HTML string, expected marker string | Passes or returns test error | Layout marker correctness |
| `treesByteIdentical(...)` | Helper function | Walks two output trees (skipping `.boris-cache`), sorts file lists, asserts identical file sets and byte-identical content for each pair | io, gpa, two root paths | Passes or propagates error | Output determinism across builds |
| `H1 pure: exact id beats glob beats role beats fallback` | Test | Calls `selectLayout` four times with `standardRules()` and asserts exact precedence outcomes for each page | Synthetic ids and roles; no I/O | `.exact`→home, `.glob`→ref, `.role`→section, `.fallback`→main | Precedence ordering: id > glob > role > fallback |
| `H1 html: data-layout markers match precedence` | Test | Full HTML compile with `standardRules()`; reads five output HTML files and checks `data-layout` marker | `compileWithRules` + fixture content | `stats.pages_written >= 5`; markers: index→"home", guides→"section", guides/getting-started→"main", reference→"section", reference/configuration→"reference" | End-to-end: selection result is reflected in rendered HTML |
| `H2 pure: equal-specificity globs are AmbiguousGlob even with same path` | Test | Calls `selectLayout` with two equal-literal-count globs both matching `reference/configuration`; repeated for same-path case | Two competing glob rules | `error.AmbiguousGlob` in both cases | Ambiguity is structural, not resolved by path equality |
| `H2 html: ambiguous globs fail without publishing HTML` | Test | Calls `compileWithRules` with ambiguous globs; checks no HTML appears in dist | Two competing glob rules; WorkDir | `error.AmbiguousGlob`; `dist/index.html` and `dist/reference/configuration.html` must not exist | Fail-closed: HTML not emitted on selection error |
| `H3 pure + html: argv/rule order does not change selection or HTML` | Test | Three permutations of `standardRules()` run through `selectLayout`, `ruleTableDigestMaterial`, and full `compileWithRules`; trees compared | Three distinct orderings of the same 3-rule set | Identical selections, identical digest material, byte-identical HTML trees | Declaration-order independence of selection, digest, and compiled output |
| `H4 fallback: target-layout beats global html-layout beats product default` | Test | Tests `target_mod.effectiveLayout` with and without `layout_path`, then `cli.parseOptions` with `--theme`, then `--target-layout`, and finally a product-default layout compile over a single in-workdir page | Synthetic `TargetSpec` structs; CLI arg slices; workdir with one index.md | Layout priority chain correct; `stats.pages_written == 1`; `dist/index.html` exists | Three-level fallback chain: target > global > product default |
| `H5 mixed theme roots rejected at target validate and select preflight` | Test | Calls `target_mod.rejectMixedThemeRoots` with a beta-main rule against an alpha fallback; and with a product-default path against a managed theme; then `compileWithRules`; checks HTML absent | Mixed-theme rule slices | `error.MixedThemeRoots` in all three cases; no HTML written | Theme root isolation enforced before HTML publication |
| `H5 missing layout file fails without silent next-rule fallback` | Test | Constructs a rule naming a non-existent layout file alongside a valid fallback rule; calls `compileWithRules` and asserts any error is returned and no HTML published | Rule with `does-not-exist.html` path | `std.meta.isError(result) == true`; `dist/index.html` absent | Missing layout fails closed; no silent skip-to-next-rule |
| `H5 traversal / cross-theme via .. is InvalidLayoutPath at every surface` | Test | Four `validateLayoutPath` calls; four `cli.parseOptions` calls with traversal paths; one `compileWithRules` call; one `compile.compileHtmlSite` call with traversal in fallback | Paths containing `..`, absolute prefix, `.` segment | `error.InvalidLayoutPath` from library; `error.InvalidValue` from CLI; no HTML written | Traversal rejected lexically at every entry point |
| `H5 invalid selectors and duplicate selectors are usage errors at parse` | Test | Five `cli.parseOptions` calls with invalid selector grammar and one duplicate, one ConflictingFlags case | Malformed `--layout-rule` args | `error.InvalidValue`, `error.DuplicateFlag`, `error.ConflictingFlags` from `cli.parseOptions` | CLI rejects malformed selectors before compilation begins |
| `H6 multi-target: isolated rules, markers, and cache namespaces` | Test | Two targets with distinct rules compiled via `compile.compileHtmlSiteMulti`; markers checked; second incremental pass; cache manifests read and compared | `targets[^1_2]` slice; WorkDir | Each site has correct layout marker for its rules; `.boris-cache/manifest.json` exists per-target; manifests differ for index (different selected layouts); no cross-target pollution | Target isolation: rules, HTML output, and cache namespaces are independent |
| `H7 incremental: changing selected layout rewrites page HTML` | Test | Two sequential `compileWithRules` calls with `incremental = true`; first with home rule, second no-op, third with alt rule | rules_v1, rules_v2, same dist | Marker is "home" after v1; no pages written on no-op; `pages_written >= 1` after v2; marker is "alt" | Incremental build detects layout-rule change and rewrites page |
| `H8 stale cleanup: removed page MD dropped; layout-rule change updates live pages` | Test | Writes local content + templates; full incremental build; deletes `extra.md`; full non-incremental build; checks `extra.html` absent; changes layout rule; incremental rebuild; checks marker | WorkDir with local content | `extra.html` absent after page removal; index marker updated after rule change | Stale HTML scrubbed on full rebuild; layout change detected on incremental rebuild |
| `H9 full vs incremental trees are byte-identical` | Test | Full build and incremental build (with second no-op incremental pass) of `standardRules()` into separate dists; `treesByteIdentical` on both pairs | `standardRules()`; two WorkDir paths | No divergence between full and incremental output (excluding cache) | Full/incremental equivalence |
| `H10 repeated full builds are byte-identical` | Test | Three independent full builds of `standardRules()` into separate dists; compared pairwise | `standardRules()`; three WorkDir paths | All three trees byte-identical | Build determinism |
| `H10 cache manifest stable across no-op incremental runs` | Test | Two sequential incremental builds with no content change; manifests read and compared; manifest content spot-checked | `standardRules()`; incremental flag | Manifests byte-identical; contain `"boris-cache-v2-layout-rules"` and `"selected_layout"` keys | Manifest stability; cache version key present |
| `hostile: more literal glob segments win; entity id is match key` | Bonus test | Three-rule set with `*/*` and `reference/*` globs; checks more-specific glob wins; checks id rule matches on entity id not path stem | Mixed rule kinds; two ids | `reference/*` result for `reference/configuration`; `.exact` result for `custom/home` | Specificity tiebreak for globs; id match is on entity id not file path |

## Hostile-case walkthrough

### Ambiguous equal-specificity globs (H2 pure)

**Injected behavior:**
Two glob rules — `reference/*` (1 literal segment: `reference`) and `*/configuration` (1 literal segment: `configuration`) — both match the entity id `reference/configuration` with equal literal segment counts. A second variant repeats this with both rules naming the same layout path.

**Wrapper boundary exercised:**
`layout_select.selectLayout`: the glob matching loop computes `globLiteralCount` for each matching rule and sets `tie = true` when two matching globs share the same count.

**Expected response:**
`error.AmbiguousGlob` in both cases. The test calls `expectError(error.AmbiguousGlob, layout_select.selectLayout(...))`.

**Forbidden unsafe response:**
Silently returning either rule's layout (first-wins or last-wins); coalescing to an arbitrary result when paths happen to be equal; returning the fallback layout.

**Evidence strength:**
Directly demonstrated — the assertion is verified by `expectError`.

**Residual gap:**
Does not test three-way ties or a mix of equal-literal and different-literal globs in the same rule set. Does not test that a more-specific glob correctly breaks the tie when one of the two ambiguous globs has more literal segments than the other (that case is the "more literal glob segments win" bonus test).

***

### Ambiguous globs fail closed — no HTML published (H2 html)

**Injected behavior:**
Same two equal-specificity glob rules as H2 pure, submitted to `compileWithRules`. The content fixture tree includes at least one page whose id matches both globs.

**Wrapper boundary exercised:**
`compile.compileHtmlSite` → `layout_select.selectLayout` per page. The compile pipeline must propagate `error.AmbiguousGlob` without writing any HTML.

**Expected response:**
`compileWithRules` returns `error.AmbiguousGlob`. Neither `dist/index.html` nor `dist/reference/configuration.html` exists after the call.

**Forbidden unsafe response:**
Writing a partial HTML output before detecting the error; writing index.html (which is not the ambiguous page) before encountering the ambiguous page; silently swallowing the error and continuing with an arbitrary selection.

**Evidence strength:**
Directly demonstrated — both `expectError` and `fileExists` checks are assertions.

**Residual gap:**
Does not verify that the error diagnostic message names the competing rules or the affected entity id. Does not test whether any partially-written dist directory is cleaned up versus left dirty.

***

### Path traversal rejected at every surface (H5-traversal)

**Injected behavior:**
Layout paths containing `..` segments (`theme_alpha ++ "/layouts/../../themes/beta/layouts/main.html"`), absolute paths (`../layouts/main.html`), dot-segment paths (`theme/./layouts/main.html`). These are injected at four surfaces: `layout_select.validateLayoutPath` directly, four `cli.parseOptions` calls, one `compileWithRules` call, and one `compile.compileHtmlSite` call with traversal in the fallback path.

**Wrapper boundary exercised:**
`layout_select.validateLayoutPath`: lexical path grammar check (no filesystem access). `cli.parseOptions`: pre-compilation validation of `--html-layout`, `--target-layout`, `--layout-rule` path arguments, and `--theme` path. `compile.compileHtmlSite`: fallback path validation.

**Expected response:**
`error.InvalidLayoutPath` from the library function; `error.InvalidValue` from `cli.parseOptions`; error from `compileWithRules` and `compile.compileHtmlSite`; no HTML written.

**Forbidden unsafe response:**
Resolving the path against the working directory and treating it as valid if the resulting file happens to not exist; passing the path to the filesystem before validation; writing any HTML before the path is validated.

**Evidence strength:**
Directly demonstrated for each entry point individually. The `validateLayoutPath` unit tests in `layout_select.zig` itself also cover the same grammar (overlapping but not redundant — the hostile test additionally verifies that the library error surfaces correctly through the compile and CLI layers).

**Residual gap:**
The validation is lexical only. A path like `themes/alpha/layouts/../../../../etc/passwd` could pass lexical validation if it contains no `..` segment — this is not tested. The test does not verify that the workspace-relative path cannot escape the workspace via symlinks on the filesystem.

***

### Missing layout file fails closed (H5-missing)

**Injected behavior:**
A layout rule names `theme_alpha ++ "/layouts/does-not-exist.html"` for the `id:index` selector. A second rule (`role:trunk → layout_section`) follows it, which would match if the engine silently skipped the first.

**Wrapper boundary exercised:**
`compile.compileHtmlSite` → layout file loading logic. The test probes whether a missing file causes an error or causes the engine to silently advance to the next applicable rule.

**Expected response:**
`std.meta.isError(result) == true`; `dist/index.html` absent.

**Forbidden unsafe response:**
Returning `CompileStats` successfully; advancing to the `role:trunk` rule (which would write index.html with the section layout); writing any HTML for any page before the missing layout is encountered.

**Evidence strength:**
Directly demonstrated. However, the exact error type is not asserted — only `std.meta.isError`. This means any error (I/O, layout-not-found, etc.) satisfies the test; the exact diagnostic class is not pinned.

**Residual gap:**
Does not assert the specific error type, so a regression that changes the error kind would not be detected unless it also started succeeding. Does not test missing fallback layout (only missing rule-specified layout).

***

### Mixed theme roots (H5-mixed)

**Injected behavior:**
A rule references `theme_beta ++ "/layouts/main.html"` while the fallback is `theme_alpha ++ "/layouts/main.html"`. A second variant mixes the product default path `"layouts/main.html"` with a managed theme fallback. Both variants are tested at the library level and through `compileWithRules`.

**Wrapper boundary exercised:**
`target_mod.rejectMixedThemeRoots`: called before compilation begins to verify all rule paths and the fallback share a common theme root prefix.

**Expected response:**
`error.MixedThemeRoots` in all cases; no HTML written.

**Forbidden unsafe response:**
Accepting the mixed set and writing HTML; silently coercing paths to a common root; applying only the fallback path's theme.

**Evidence strength:**
Directly demonstrated.

**Residual gap:**
Does not test three-theme mixes. Does not test a mix where all paths are under the same prefix string by coincidence (e.g., `themes/alpha` vs `themes/alpha-ext`).

***

### Rule declaration order independence (H3)

**Injected behavior:**
Three permutations (a, b, c) of the same three rules (id, role, glob) in different declaration orders are passed to `selectLayout`, `ruleTableDigestMaterial`, and `compileWithRules` for four distinct pages.

**Wrapper boundary exercised:**
`layout_select.selectLayout` precedence algorithm (which applies kind rank, not array index) and `ruleTableDigestMaterial` (which sorts a copy canonically before serializing).

**Expected response:**
`sa.layout_path == sb.layout_path == sc.layout_path` and identical `kind` for all four pages across all three permutations. Digest strings byte-equal. HTML trees byte-identical.

**Forbidden unsafe response:**
A tie-break by array index that causes the role rule to win over the glob rule when presented in a certain order; a digest that includes the original declaration order.

**Evidence strength:**
Directly demonstrated for four specific ids. The byte-identity check is comprehensive over the full output tree.

**Residual gap:**
Only three permutations of a three-rule set are tested. Pathological cases (N=256 rules, adversarial sort orders) are not covered.

***

### Incremental cache detects layout-rule change (H7)

**Injected behavior:**
First build assigns `index → layout_home` (rule v1). A second build (no-op) with the same rules. A third build changes `index → layout_alt` (rule v2).

**Wrapper boundary exercised:**
The incremental cache in `compile.compileHtmlSite` must store the `selected_layout` per page in its manifest and invalidate pages whose selected layout has changed between builds.

**Expected response:**
First build: marker is "home". No-op: `stats_noop.pages_written == 0`. Third build: `stats_change.pages_written >= 1`; marker is "alt".

**Forbidden unsafe response:**
Serving the cached "home" HTML after the rule change because the Markdown content was unchanged.

**Evidence strength:**
Directly demonstrated. The cache manifest schema is also spot-checked in H10 for the `selected_layout` key.

**Residual gap:**
Does not test that a rule deletion (not just change) causes re-evaluation. Does not test that adding a new rule that matches a previously fallback-selected page causes a rebuild.

***

### Multi-target cache namespace isolation (H6)

**Injected behavior:**
Two `TargetSpec` structs with distinct names, output dirs, and rule sets are compiled via `compile.compileHtmlSiteMulti`. An incremental pass follows.

**Wrapper boundary exercised:**
Cache manifest paths (`.boris-cache/manifest.json` relative to each target's `output_dir`) and that the cache key for each target incorporates the target name and rule table digest so they cannot share cache entries.

**Expected response:**
`site-a/.boris-cache/manifest.json` and `site-b/.boris-cache/manifest.json` both exist after incremental pass; manifests are not byte-equal (because index is mapped to different layouts in each target); each target's HTML carries the correct marker for its rules; no cross-target file pollution.

**Forbidden unsafe response:**
Both targets writing to a shared cache directory; target-b cache entries overwriting target-a entries; target-b layout selection influencing target-a HTML.

**Evidence strength:**
Directly demonstrated. The manifest inequality check (`!std.mem.eql(u8, man_a, man_b)`) is a structural assertion, not just a file-existence check.

**Residual gap:**
Does not test three or more targets. Does not test targets that share a subset of rules (and should therefore share only the relevant subset of cache entries, not the full manifest).

***

### Full vs incremental byte identity (H9)

**Injected behavior:**
A full build and an incremental build (followed by a second no-op incremental pass) of the same `standardRules()` over the same fixture content into separate output directories.

**Wrapper boundary exercised:**
`treesByteIdentical` — which walks both trees (excluding `.boris-cache/`), sorts file lists, and compares file content byte-by-byte.

**Expected response:**
No divergence in any published file between the full and incremental build trees.

**Forbidden unsafe response:**
An incremental build that writes a different `<meta>` timestamp, different asset hash suffix, or different HTML whitespace from the full build.

**Evidence strength:**
Directly demonstrated. The `.boris-cache` exclusion is intentional and documented in `treesByteIdentical`; cache manifest format differences between full and incremental are not tested here but are covered partially in H10.

**Residual gap:**
Only exercises `standardRules()`. Does not test full-vs-incremental equivalence after a mid-stream content change (where some pages have stale cache entries).

## Control flow

Each test follows one of two patterns: pure (no I/O) or integration (WorkDir + compile). Representative flows:

**Pure selection test (H1 pure):**

```text
test "H1 pure..."
    → layout_select.selectLayout(entity_id, role, &rules, fallback)
        → exact id scan → found → return Selection{.kind=.exact, ...}
        → (or) glob scan → best_lit/tie logic → return Selection{.kind=.glob, ...}
        → (or) role scan → return Selection{.kind=.role, ...}
        → (or) return Selection{.kind=.fallback, ...}
    → expectEqual(expected_kind, s.kind)
    → expectEqualStrings(expected_path, s.layout_path)
```

**Integration compile test (H1 html, H2 html, H5-traversal, H6, H7, H8, H9, H10):**

```text
test "H..."
    → WorkDir.create(gpa, io, label)     // mkdir test-output/layout-hostile-{label}-{rnd}
    → compileWithRules(io, gpa, dist, rules, fallback, incremental)
        → compile.compileHtmlSite(io, gpa, .{...})
            → target_mod.rejectMixedThemeRoots(fallback, rules)   // if applicable
            → layout_select.validateLayoutPath(each path)         // if applicable
            → [per page] layout_select.selectLayout(id, role, rules, effective_fallback)
                → error.AmbiguousGlob | error.InvalidLayoutPath | Selection
            → [on Selection] load layout template from disk
                → I/O error if file absent
            → render HTML into dist
            → update .boris-cache/manifest.json                   // if incremental
        → return CompileStats | error
    → expectError / expect / expectMarker / expectEqualStrings assertions
    → work.cleanup()                     // deleteTree test-output/layout-hostile-...
```

**CLI parse test (H4 CLI surface, H5 selectors):**

```text
test "H..."
    → cli.parseOptions(allocator, &argv_slice)
        → validate --html-layout / --target-layout / --layout-rule paths
            → layout_select.validateLayoutPath(path) → error.InvalidLayoutPath
            → surface as error.InvalidValue
        → validate selector grammar
            → layout_select.parseSelector(raw) → error.InvalidSelector etc.
            → surface as error.InvalidValue
        → detect duplicate selectors → error.DuplicateFlag
        → detect conflicting flags → error.ConflictingFlags
    → expectError(error.InvalidValue | error.DuplicateFlag | ..., result)
```

**Digest order-independence (H3):**

```text
test "H3..."
    → layout_select.ruleTableDigestMaterial(gpa, "default", &rules_a, fallback)
        → gpa.alloc(LayoutRule, rules.len)    // copy
        → sortRulesCanonical(sorted)          // sort by (kind rank, value, path)
        → serialize to length-delimited text
        → return []u8
    → (repeated for rules_b, rules_c)
    → expectEqualStrings(da, db); expectEqualStrings(da, dc)
```
