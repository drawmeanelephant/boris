---
title: "`src/intelligence.zig` evidence and cases"
id: docs/boris/src/intelligence/evidence-and-cases
parent: docs/boris/src/intelligence
status: draft
tags: [boris, zig, source-reference, evidence, intelligence]
---

# `src/intelligence.zig` evidence and cases

## Test harness construction

The test module is assembled as follows in `build.zig`:

```zig
const intelligence_mod = b.createModule(.{
    .root_source_file = b.path("src/intelligence.zig"),
    .target = target,
    .optimize = optimize,
});
const intelligence_tests = b.addTest(.{
    .root_module = intelligence_mod,
});
const run_intelligence_tests = b.addRunArtifact(intelligence_tests);
run_intelligence_tests.setCwd(b.path("."));
```

No imports are declared beyond the implicit `std`. No `addOptions` call is made, so there is no `build_options` comptime configuration. No renderer module is linked: `intelligence_tests` has no dependency on `render_mod`.

The test binary is a self-contained Zig test executable whose only external dependency is `std`. It is added to the default `test_step`, meaning `zig build test` runs it unconditionally. The working directory is set to the package root, which is relevant for any test that might attempt filesystem access, though the current tests do not.

The production binary (`exe`) does **not** have `intelligence_mod` as a declared import in the build configuration inspected. Whether the module is reached transitively through another module (e.g., a module not shown in `build.zig`'s top-level declarations) is **uncertain**.

The rendering seam (`src/render.zig`) is irrelevant to this module and is never linked into the intelligence test binary.

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `analyze` | `pub fn` | Main analysis entry point; accepts frozen page/edge snapshot | Allocator, `[]const Page`, `[]const Edge`, `Options` | Returns `Report` with populated `summary`, `findings`, and optionally `impact`; returns error on allocation failure | Caller-owned inputs; report owns only its lists; `errdefer` cleans on error |
| `Endpoint` / `EndpointType` | `pub struct` / `pub enum` | Typed graph endpoint (page ID or source path) | Enum `.page` / `.source`; `[]const u8` value | `less` provides total order: type first (`.page < .source`), then lexicographic value; `eql` checks both fields | Deterministic sort; used as map key |
| `Page` | `pub struct` | Minimal page record for analysis | `id: []const u8`, optional `parent: ?[]const u8` | Provides the page inventory and trunk/satellite classification | Caller-owned strings; not validated for uniqueness |
| `Edge` | `pub struct` | Directed typed relationship | `from`, `to: Endpoint`, `kind: []const u8` | `kind == "reference"` gates unreferenced-page detection; any kind increments incoming count | Edge kinds are caller-asserted; no enum constraint |
| `Report` | `pub struct` | Analysis output; owns `findings` and `impact` ArrayLists | Initialized by `analyze` | `deinit` frees both lists using stored `allocator`; caller must not use report after `deinit` | Report owns lists; borrows endpoint strings from caller |
| `Options` | `pub struct` | Configures thresholds and optional impact root | `fan_in_threshold: usize = 0`, `impact: ?Endpoint = null` | `fan_in_threshold == 0` disables hotspot detection; non-null `impact` triggers `collectImpact` | Zero threshold = disabled; non-null endpoint = impact analysis |
| `test "analysis distinguishes parent edges from reference edges"` | inline test | Verifies parent-typed edges are not counted as references for unreferenced detection | 2 pages (`index`, `guide` with parent `index`); 1 edge with `kind = "parent"` | `summary.unreferenced_pages == 2`; both pages are unreferenced because only reference-kind edges count | Parent edges are navigation structure, not incoming references |
| `test "analysis sorts findings and computes multi-hop impact"` | inline test | Verifies BFS impact traversal and deterministic sort of impact list | 3 pages (`a`, `b`, `c`); 2 reference edges: `c→b` and `b→a`; `Options.impact = page "a"` | `impact.items.len == 2`; items are `"b"` then `"c"` in that order (lexicographic within type) | Multi-hop reverse traversal; root excluded from impact set; output sorted |
| `test "analysis reports source fan-in hotspots"` | inline test | Verifies fan-in counting and hotspot detection on source endpoints | 0 pages; 2 edges both targeting `source "includes/x.md"` with `kind = "include"`; `fan_in_threshold = 2` | `source_endpoints == 1`, `hotspots == 1`, `findings[^1_0].count == 2` | Distinct source endpoint counting; fan-in accumulation; finding count field |
| `collectImpact` (private) | `fn` | BFS traversal of reverse-edge graph from a root endpoint | Allocator, edges, root endpoint, output list | Appends all endpoints that have a directed path to root, excluding root itself | Cycle-safe via `seen` list; correct BFS termination |
| `findIncoming` (private) | `fn` | Linear scan for existing `Incoming` entry by endpoint | `[]const Incoming`, `Endpoint` | Returns `?usize` index of matching entry or `null` | Linear search; O(n) per edge; correctness depends on `Endpoint.eql` |
| `lessFinding` (private) | `fn` | Sort comparator for `Finding` | Two `Finding` values | Orders by endpoint first (type then value), then by `FindingCode` enum integer on tie | Deterministic finding order in report |
| `lessEndpoint` (private) | `fn` | Sort comparator for `Endpoint` | Two `Endpoint` values | Delegates to `Endpoint.less` | Deterministic impact list order |

## Behavioral walkthrough

### Parent edge vs. reference edge discrimination

**Behavior demonstrated:**
The `analyze` function walks all pages and, for each page, scans all edges to find one where `edge.kind == "reference"` and `edge.to` matches the page endpoint. Only if such an edge exists is the page considered referenced. An edge with `kind = "parent"` does not satisfy this condition and is not counted.

**Code path:**

```text
analyze(pages, edges, options)
    → for each page, build Endpoint{.type=.page, .value=page.id}
    → for each edge: check edge.kind.len==9 && eql(edge.kind,"reference") && Endpoint.eql(edge.to, endpoint)
    → if no matching reference edge: unreferenced_pages += 1; append finding
```

**Test assertion:**
`expectEqual(@as(usize, 2), report.summary.unreferenced_pages)` — both pages are unreferenced despite the parent edge from `guide` to `index`.

**Evidence strength:** directly demonstrated by inline test.

**Residual gap:**
An edge with `kind = "references"` (length 10) or `kind = "REFERENCE"` (wrong case) would also be treated as non-reference. The test does not cover near-miss kind strings. The length pre-check (`edge.kind.len == 9`) is a micro-optimization that is fragile to kind-string changes.

***

### Multi-hop impact traversal and sort determinism

**Behavior demonstrated:**
`collectImpact` is called with root `page "a"`. It initializes `seen = [a]`, then at cursor 0 scans edges for those targeting `a`, finding `b→a`, and appends `b` to `seen`. At cursor 1 it scans for edges targeting `b`, finding `c→b`, and appends `c`. At cursor 2, no edges target `c`, so the BFS terminates. All seen entries except the root are emitted to the output list. The output list is then sorted by `lessEndpoint` before return.

**Code path:**

```text
analyze → options.impact = page "a" → collectImpact(alloc, edges, page "a", &report.impact)
    → seen = [page "a"]
    → cursor=0: edge b→a matches target; b not in seen → append b
    → cursor=1: edge c→b matches target; c not in seen → append c
    → cursor=2: no edges target c → BFS ends
    → for seen[1..]: append page "b", page "c" to output
    → sort output by Endpoint.less
```

**Test assertion:**
`expectEqual(2, impact.items.len)`, `expectEqualStrings("b", impact.items[^1_0].value)`, `expectEqualStrings("c", impact.items[^1_1].value)`.

**Evidence strength:** directly demonstrated by inline test.

**Residual gap:**
The test uses a strictly linear chain (c→b→a) where lexicographic and BFS-discovery order coincide. A diamond dependency or out-of-order edge list is not tested. The cycle-prevention guard in `collectImpact` is not exercised by this test — whether it correctly handles a graph containing `a→b→a` is **uncertain** (structurally present, but not demonstrated).

***

### Fan-in hotspot detection on source endpoints

**Behavior demonstrated:**
Two edges both have `to = source "includes/x.md"`. The `incoming` tracking appends `{endpoint: source "includes/x.md", count: 1}` on the first edge, then increments to `count: 2` on the second. `known_sources` registers one distinct key. After edge processing, `source_endpoints = 1`. Because `fan_in_threshold == 2` and `entry.count (2) >= 2`, one hotspot finding is appended with `count: 2`.

**Code path:**

```text
analyze(pages=[], edges=[a→x, b→x], options={fan_in_threshold=2})
    → pages loop: 0 pages, summary.pages=0
    → edges loop:
        edge a→x: findIncoming([],x)=null → append {x,1}; known_sources.put("includes/x.md")
        edge b→x: findIncoming([{x,1}],x)=0 → items[^1_0].count=2; source already in known_sources
    → source_endpoints = 1
    → unreferenced-page loop: 0 pages → 0 unreferenced
    → fan_in loop (threshold=2): entry {x,2}: 2>=2 → hotspots+=1; append finding{fan_in_hotspot, x, count:2}
    → sort findings
```

**Test assertions:**
`expectEqual(1, summary.source_endpoints)`, `expectEqual(1, summary.hotspots)`, `expectEqual(2, findings.items[^1_0].count)`.

**Evidence strength:** directly demonstrated by inline test.

**Residual gap:**
The test uses `pages = &.{}` (empty), so the interaction between hotspot detection and unreferenced-page detection in the same report is untested. Hotspot detection for `.page`-type endpoints (rather than `.source`) is not tested. The `fan_in_threshold = 1` boundary (any incoming edge triggers a hotspot) and `fan_in_threshold = 0` (disabled) are not tested with explicit assertions.

***

## Control flow

```text
zig build test
    → intelligence_tests binary (root: src/intelligence.zig, no imports, no renderer link)
        → test "analysis distinguishes parent edges from reference edges"
            → analyze(testing.allocator, pages[^1_2], edges[^1_1]{kind="parent"}, .{})
                → summary.pages=2, roots=1, satellites=1
                → incoming: [{page "index", 1}]
                → unreferenced scan:
                    "index": no reference edge → unreferenced_pages=1, finding appended
                    "guide": no reference edge → unreferenced_pages=2, finding appended
                → sort findings
                → return Report
            → expectEqual(2, unreferenced_pages) → PASS
            → report.deinit()

        → test "analysis sorts findings and computes multi-hop impact"
            → analyze(testing.allocator, pages[^1_3], edges[^1_2]{refs}, {impact=page "a"})
                → unreferenced scan: "a" has ref edge from b → referenced
                                      "b" has ref edge from c → referenced
                                      "c" has no ref edge → unreferenced_pages=1
                → collectImpact(alloc, edges, page "a", &impact)
                    → BFS: seen=[a] → cursor 0: append b → cursor 1: append c → done
                    → output: [b, c]
                → sort impact by Endpoint.less → [b, c] (already lex order)
                → return Report
            → expectEqual(2, impact.items.len) → PASS
            → expectEqualStrings("b", impact[^1_0].value) → PASS
            → expectEqualStrings("c", impact[^1_1].value) → PASS
            → report.deinit()

        → test "analysis reports source fan-in hotspots"
            → analyze(testing.allocator, &.{}, edges[^1_2]{includes}, {fan_in_threshold=2})
                → incoming: [{source "includes/x.md", 2}]; known_sources: {"includes/x.md"}
                → source_endpoints=1; no unreferenced pages (0 pages)
                → hotspot: 2>=2 → hotspots=1, findings=[{fan_in_hotspot, source x, count:2}]
                → return Report
            → expectEqual(1, source_endpoints) → PASS
            → expectEqual(1, hotspots) → PASS
            → expectEqual(2, findings[^1_0].count) → PASS
            → report.deinit()
```
