---
title: "`src/layout_select.zig` evidence and cases"
id: docs/boris/src/layout_select/evidence-and-cases
parent: docs/boris/src/layout_select
status: draft
tags: [boris, zig, source-reference, evidence, layout_select]
---

# `src/layout_select.zig` evidence and cases

## Test harness construction

The in-file tests are compiled as part of the main unit test binary whenever the module is included as a test root or transitively by the test runner. They require no build options, linked C libraries, or external fixtures. The only allocator used is `std.testing.allocator` (in `ruleTableDigestMaterial ignores declaration order`) and direct stack arrays for all other tests. There is no hostile C implementation involved.

The companion `src/layout_select_hostile_test.zig` imports this module as `const layout_select = @import("layout_select.zig")` and additionally imports `compile.zig`, `target.zig`, `page.zig`, and `cli.zig`. It drives full HTML compile rounds using fixture content under `docs/contracts/fixtures/layout-rules/hostile/` and writes disposable output trees under `test-output/layout-hostile-<label>-<hex4>/` with cleanup via `WorkDir.cleanup`. It uses `std.testing.io` (Zig's injectable I/O abstraction) and `std.testing.allocator`. It is invoked by `zig build test` and `zig build test-layout-hostile` (confirmed in the hostile test module docstring; the exact build step declaration in `build.zig` was not inspected, so the step name is contract-only).

The production binary cannot accidentally use the hostile test code—there is no conditional compilation or linker flag that would pull `layout_select_hostile_test.zig` into a non-test build. It is only a test root.

## Tested declarations and entry points

### In-file tests

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| --- | --- | --- | --- | --- | --- |
| `validateLayoutPath rejects escapes and absolute forms` | test | Layout path grammar | Valid paths + 10 invalid forms (empty, abs, `..`, `.`, `\\`, double slash, trailing slash, drive letter) | Valid → no error; invalid → `error.InvalidLayoutPath` | Lexical traversal-rejection and segment grammar |
| `parseSelector closed grammar` | test | Selector token grammar | `id:index`, `glob:reference/*`, `role:trunk`, `layout:home`, bare `index`, `role:branch`, `id:`, `glob:ref*`, `glob:**`, `glob:/abs`, `glob:a//b`, `id:bad id` | Kind+value returned for valid; error variants for invalid | Closed three-prefix grammar, entity-id and glob-pattern constraints |
| `globMatches segment rules` | test | Glob segment matching | 9 `(pattern, id)` pairs covering single wildcard, depth mismatch, segment-level prefix, multi-segment, case sensitivity | Expected true/false per case | Byte-exact case-sensitive single-segment `*` semantics |
| `selectLayout precedence exact > glob > role > fallback` | test | Four-tier precedence | 3-rule table; 4 entity/role combinations | `.exact` → `layouts/exact.html`; `.glob` → `layouts/glob.html`; `.role` → `layouts/role.html`; `.fallback` → `layouts/main.html` | Precedence order; `kind` field correctness |
| `selectLayout more literal segments wins among globs` | test | Glob specificity tiebreak | `*/*` (0 literals) and `reference/*` (1 literal), entity `reference/configuration` | `layouts/ref.html` selected | Most-specific glob wins by `globLiteralCount` |
| `selectLayout equal-specificity globs are ambiguous` | test | Ambiguous glob detection | Two 1-literal globs both matching `reference/configuration`; same with identical paths | `error.AmbiguousGlob` in both cases | Ambiguity is path-independent |
| `rejectDuplicateSelectors independent of path equality` | test | Duplicate-selector guard | Two `id:index` rules with same path; one `id:index` + one `role:trunk` | Duplicate → `error.DuplicateSelector`; non-duplicate → ok | Equality is `(kind, value)` byte-exact, not `layout_path` |
| `rule order does not affect selection` | test | Declaration-order independence | Same 2 rules in two orderings; same entity | `layout_path` and `kind` identical across orderings | Declarative-not-procedural precedence |
| `ruleTableDigestMaterial ignores declaration order` | test | Digest stability | Same 2 rules in two orderings, `gpa` allocator | Digest bytes identical | `sortRulesCanonical` normalizes order before serialization |
| `id override is exact match key not path` | test | Entity-id override semantics | Rule `id:custom/home`; entity id `custom/home` | `home.html` selected; glob rule irrelevant | ID matching uses entity id, not source path stem |

### Hostile test cases (from `src/layout_select_hostile_test.zig`)

| Test | Kind | Purpose | Main assertion |
| --- | --- | --- | --- |
| `H1 pure` | hostile/pure | Precedence verified with realistic fixture paths | `.exact`/`.glob`/`.role`/`.fallback` confirmed for 4 entity/role combos |
| `H1 html` | hostile/integration | HTML marker confirms layout selection propagates to output | `data-layout` attribute matches expected layout per page |
| `H2 pure` | hostile/pure | Equal-specificity glob ambiguity (including same-path case) | `error.AmbiguousGlob` from `selectLayout` |
| `H2 html` | hostile/integration | Ambiguous globs abort HTML compile without partial output | No `index.html` or `reference/configuration.html` written |
| `H3 pure + html` | hostile/integration | 3-permutation rule order invariance (pure + digest + byte-identical HTML trees) | All three permutations yield identical selections, digests, and output trees |
| `H4 fallback` | hostile/integration | Fallback chain: `target-layout` > `html-layout`/theme > product default | CLI options parsed and `effectiveLayout` resolves correctly; product default still builds |
| `H5 mixed theme roots` | hostile/integration | Mixed-theme-root rejection at `rejectMixedThemeRoots` and compile | `error.MixedThemeRoots` before output |
| `H5 missing layout file` | hostile/integration | Missing layout path fails closed without silent rule fallback | Error returned; no HTML written |
| `H5 traversal` | hostile/integration | `..`/absolute path rejection at pure, CLI, and compile surfaces | `error.InvalidLayoutPath` at every layer; no HTML written |
| `H5 invalid/duplicate selectors` | hostile/integration | Bad selector grammar and duplicate selectors are CLI usage errors | `error.InvalidValue` or `error.DuplicateFlag` from `cli.parseOptions` |
| `H6 multi-target` | hostile/integration | Target isolation: distinct rules, markers, and cache namespaces | Each target produces correct marker; manifests differ; no cross-contamination |
| `H7 incremental` | hostile/integration | Layout change forces page rewrite; same rules suppress rewrite | `pages_written >= 1` on change; `pages_written == 0` on no-op; HTML marker updated |
| `H8 stale cleanup` | hostile/integration | Removed page scrubbed; layout rule change updates live pages | `extra.html` absent after source delete; `index.html` marker updated |
| `H9 full vs incremental` | hostile/integration | Full and incremental builds are byte-identical over published HTML | `treesByteIdentical` passes for `full` vs `inc` trees |
| `H10 repeated builds` | hostile/integration | Repeated full builds are byte-identical | Three distinct output trees pass `treesByteIdentical` pairwise |
| `H10 manifest` | hostile/integration | Cache manifest stable across no-op incremental runs | Manifest bytes identical across two identical incremental runs |
| `hostile: more literal glob segments / entity id is match key` | hostile/pure | Combined specificity and id-override semantics | `reference/*` beats `*/*`; exact id match beats glob |

## Hostile-case walkthrough

### `H2: equal-specificity globs produce AmbiguousGlob, not arbitrary selection`

**Injected behavior:**
Two glob rules (`reference/*` and `*/configuration`) each have 1 literal segment. Both match `reference/configuration`. A second variant provides the same layout path for both globs.

**Wrapper boundary exercised:**
`selectLayout` at the glob tier. After the exact-id check finds no match, the function iterates glob rules, tracks `best_lit` and `tie`. When `lit == best_lit` for a second match, `tie` is set to `true` and `best_idx` is not updated (the first-found index is retained). After the glob loop, if `tie` is `true`, the function returns `error.AmbiguousGlob` unconditionally, before consulting the role or fallback tier.

**Expected response:**
`error.AmbiguousGlob`. This is directly demonstrated by the in-file test `selectLayout equal-specificity globs are ambiguous` and by `H2 pure`. `H2 html` additionally demonstrates that the full compile pipeline propagates this error and writes no HTML.

**Forbidden unsafe response:**
Silently selecting the first-declared glob (declaration-order dependence). Silently selecting either glob when both point to the same path. Proceeding to role or fallback tier. Writing any partial HTML output before the error surfaces.

**Evidence strength:** Directly demonstrated (pure call) and directly demonstrated (HTML compile abort without partial output).

**Residual gap:**
The test uses a 2-rule table. Behavior with 3+ equal-specificity globs matching simultaneously is not directly tested, though the code path handles any `tie == true` case uniformly. Glob matches of 0 literal segments (`*/*` against a 2-segment id) with a single match are not ambiguous but are not included in the hostile test—only the specificity-win case appears in `hostile: more literal glob segments`.

***

### `H3: rule-table declaration order does not affect layout selection or digest`

**Injected behavior:**
Three permutations of the same 3-rule table (`role:trunk`, `glob:reference/*`, `id:index`) are built in all orderings (a: role→glob→id; b: id→role→glob; c: glob→id→role).

**Wrapper boundary exercised:**
`selectLayout` (precedence algorithm), `ruleTableDigestMaterial` (sort-then-serialize path), and `compile.compileHtmlSite` (full build).

**Expected response:**
For each of 4 test entities, all three permutations return the same `layout_path` and `kind`. Digest strings from all three permutations are byte-identical. HTML output trees from all three builds are byte-for-byte identical per `treesByteIdentical`.

**Forbidden unsafe response:**
Any permutation producing a different layout selection for any page. Any permutation producing a different digest string. Any permutation producing HTML files with a different `data-layout` attribute value or different file contents.

**Evidence strength:** Directly demonstrated (pure calls + digest + HTML tree comparison).

**Residual gap:**
Only three of six possible permutations are tested (a, b, c). The test covers all three rule kinds appearing in the table but does not test a table containing two globs with differing specificity across permutations.

***

### `H5 traversal: .. and absolute paths rejected at every API surface`

**Injected behavior:**
Layout path `theme_alpha ++ "/layouts/../../themes/beta/layouts/main.html"` is injected at: (1) direct `validateLayoutPath` call; (2) `--layout-rule` CLI argument; (3) `--html-layout` CLI argument; (4) `--target-layout` CLI argument; (5) `--theme` CLI argument with a `../evil` path; (6) `compile.compileHtmlSite` library call with a `..`-containing rule path; (7) `compile.compileHtmlSite` with `layout_path = "../layouts/main.html"`.

**Wrapper boundary exercised:**
`validateLayoutPath` in `layout_select.zig` (lexical segment check), `cli.parseOptions` (which calls the validator at parse time), and the compile-time path preflight in `compile.compileHtmlSite`.

**Expected response:**
`error.InvalidLayoutPath` at the pure call; `error.InvalidValue` at every `cli.parseOptions` variant. An error (class not pinned by the test) from `compile.compileHtmlSite`. No HTML written in any case.

**Forbidden unsafe response:**
Opening a file at any path containing `..` or an absolute root. Resolving the `..` segments against the working directory and opening a file in a different theme tree. Writing any HTML output before failing. Silently treating the traversal path as a relative path from the content root.

**Evidence strength:** Directly demonstrated across pure, CLI, and compile-level surfaces.

**Residual gap:**
The test uses `\\`-backslash paths only via the in-file `validateLayoutPath rejects escapes and absolute forms` test (a single backslash-prefixed path). The hostile test H5 does not directly test backslash-containing paths through the CLI or compile surfaces. Windows drive letter paths (`C:/...`) are tested only in the in-file unit tests.

***

### `H5 missing layout file: no silent next-rule fallback`

**Injected behavior:**
A rule table contains an exact-id rule (`id:index`) pointing to a path that does not exist on disk (`theme_alpha ++ "/layouts/does-not-exist.html"`), followed by a role rule that would win for the same page if the compiler silently skipped the missing exact match.

**Wrapper boundary exercised:**
`selectLayout` returns the exact-id match (the nonexistent path), and the HTML compiler attempts to open it. The contract being tested is that the compiler does not catch the missing-file error and retry with the next rule.

**Expected response:**
An error is returned from `compileWithRules`. No `dist/index.html` is written.

**Forbidden unsafe response:**
Silently skipping the missing layout and falling through to the role rule. Treating any I/O error on a selected layout as a fallback trigger. Writing HTML using the role layout when the exact-id layout was missing.

**Evidence strength:** Directly demonstrated (HTML compile error, no output). The exact error type is not asserted (only `std.meta.isError(result)` is checked), so the specific error variant is contract-only for this test.

**Residual gap:**
The test confirms fail-closed behavior for a missing exact-id layout, but does not test the equivalent for a missing glob-matched layout or a missing fallback layout. No test covers the case where a layout file exists but is unreadable (permissions).

***

### `H7: incremental build detects selected-layout change and rewrites page`

**Injected behavior:**
Two incremental build rounds over the same content: round 1 uses `id:index → layout_home`; round 2 uses `id:index → layout_alt`. A no-op round (same rules as round 1, repeated) is also run between them.

**Wrapper boundary exercised:**
The incremental cache key includes the resolved layout path (confirmed by the manifest containing `selected_layout`). When the selected layout for a page changes between rounds, the cache entry is invalidated and the page is rebuilt.

**Expected response:**
Round 1: `data-layout="home"` in `dist/index.html`. No-op round: `pages_written == 0`. Round 2: `pages_written >= 1`; `data-layout="alt"` in `dist/index.html`; HTML bytes differ between round 1 and round 2.

**Forbidden unsafe response:**
Serving stale HTML from round 1 after the layout rule changes. Reporting `pages_written == 0` (false no-op) when the layout changed. Overwriting the page with incorrect content.

**Evidence strength:** Directly demonstrated.

**Residual gap:**
The test changes the exact-id rule for a single page. It does not test cache invalidation when a glob rule's layout path changes and multiple pages are affected simultaneously. It does not test the case where the fallback layout changes without any rule change.

***

### `H10: repeated full builds are byte-identical`

**Injected behavior:**
Three independent full (non-incremental) builds of the same content+rules into three distinct output directories, in sequence.

**Wrapper boundary exercised:**
The entire layout selection and HTML assembly pipeline must not incorporate any non-deterministic input (timestamps, hash-map ordering, random suffixes). The `ruleTableDigestMaterial` sort ensures digest stability; the test confirms the downstream HTML outputs are also stable.

**Expected response:**
`treesByteIdentical` passes for all three pairwise comparisons of the output trees.

**Forbidden unsafe response:**
Any byte difference in output HTML, including attribute ordering, whitespace, or timestamp strings in rendered output.

**Evidence strength:** Directly demonstrated.

**Residual gap:**
The test uses the `standardRules()` fixture, which is a 3-rule table. It does not test with empty rule tables, single-rule tables with each selector kind, or at the `max_rules_per_target` boundary.

## Control flow

### In-file `selectLayout` call flow

```text
caller provides (entity_id, role, rules[], fallback_layout)
    │
    ├─ Exact-id scan: iterate rules, match kind==.id and value==entity_id
    │       duplicate found → error.DuplicateSelector
    │       single match   → return Selection{.exact, layout_path, rule_index}
    │
    ├─ Glob scan: iterate rules where kind==.glob
    │       globMatches(r.value, entity_id)?
    │           yes → compute globLiteralCount(r.value)
    │               lit > best_lit  → update best_idx, best_lit, tie=false
    │               lit == best_lit → tie=true
    │       after loop: tie==true → error.AmbiguousGlob
    │                   best_idx set → return Selection{.glob, layout_path, rule_index}
    │
    ├─ Role scan: iterate rules where kind==.role
    │       value == role.name()?
    │           duplicate → error.DuplicateSelector
    │           single match → return Selection{.role, layout_path, rule_index}
    │
    └─ Fallback: return Selection{.fallback, fallback_layout, null}
```


### Hostile test H3 full flow

```text
layout_select_hostile_test.zig: test "H3 pure + html"
    │
    ├─ Pure checks (3 permutations × 4 pages):
    │       selectLayout(page.id, page.role, &perm, layout_main)
    │           → layout_select.selectLayout (in-process, no I/O)
    │           → asserting .layout_path and .kind identical across permutations
    │
    ├─ Digest checks (3 permutations):
    │       ruleTableDigestMaterial(gpa, "default", &perm, layout_main)
    │           → sortRulesCanonical (copy + sort)
    │           → serialize "target:\nfallback:\nrule:…\n" per sorted rule
    │           → asserting byte-identical across permutations
    │
    └─ HTML tree checks (3 separate compileWithRules calls into WorkDir):
            compile.compileHtmlSite(io, gpa, options{layout_rules: &perm})
                → pipeline calls rejectDuplicateSelectors (preflight)
                → per-page: selectLayout → resolved layout path
                → HTML assembler opens layout file, writes output HTML
            treesByteIdentical(io, gpa, dist_a, dist_b)
            treesByteIdentical(io, gpa, dist_a, dist_c)
                → walk both trees, sort, pairwise byte-compare file contents
```


### `validateLayoutPath` lexical check flow

```text
validateLayoutPath(path)
    │
    ├─ path.len == 0                  → error.InvalidLayoutPath
    ├─ path[^1_0] == '/' or '\\'         → error.InvalidLayoutPath
    ├─ path[^1_1] == ':'                  → error.InvalidLayoutPath  (drive letter)
    ├─ path[last] == '/' or '\\'       → error.InvalidLayoutPath
    │
    └─ segment iteration:
           for each segment between '/' separators:
               '\\' found mid-path      → error.InvalidLayoutPath
               empty segment            → error.InvalidLayoutPath  (double slash)
               seg == "." or ".."       → error.InvalidLayoutPath
           seg_count == 0 (unreachable given prior checks)
                                        → error.InvalidLayoutPath
           → ok (void return)
```
