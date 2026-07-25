---
title: "`src/harness.zig` evidence and cases"
id: docs/boris/src/harness/evidence-and-cases
parent: docs/boris/src/harness
status: draft
tags: [boris, zig, source-reference, evidence, harness]
---

# `src/harness.zig` evidence and cases

## Test harness construction

`src/harness.zig` is **not registered in `build.zig`**. No `b.addTest`, `b.createModule`, or step dependency references this file. It exists on disk and compiles as a standalone module if invoked directly, but is not part of `zig build test`, `zig build test-harness`, or any other declared step.

The file imports the following modules at top level:

```zig
const pipeline   = @import("pipeline.zig");
const graph_mod  = @import("graph.zig");
const diag       = @import("diag.zig");
const frontmatter = @import("frontmatter.zig");
const parser     = @import("parser.zig");
const apex       = @import("apex.zig");
const aside      = @import("aside.zig");
const assemble   = @import("assemble.zig");
const compile    = @import("compile.zig");
const scanner    = @import("scanner.zig");
const page_mod   = @import("page.zig");
const rag        = @import("rag.zig");
```

All imports are direct peer `.zig` files — no hostile module substitution, no `build_options`, no `@cImport` in this file. The `apex` import resolves to the normal `src/apex.zig`, which in turn `@cImport`s `vendor/apex/apex.h` and links the real ApexMarkdown static libraries. Because there is no build step for this file, the Apex static libs would need to be pre-built (`zig build build-apex`) for the imports to link successfully if a developer tried to compile the file directly.

The `WorkDir` struct at the top of the file (see below) is the only public export. It is used by every test in the file as the primary fixture management primitive.

The production binary cannot accidentally use this file — it is never linked into `src/main.zig` or any module that feeds the `boris` executable.

***

## Tested declarations and entry points

### `WorkDir` type

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `WorkDir.create` | Public fn | Create a unique `test-output/<label>-<hex>/` directory | GPA, Io, label string | Returns `WorkDir` with owned `rel` path; directory exists on disk | `output_root` is `"test-output"` (gitignored); suffix is 8 random bytes hex-encoded |
| `WorkDir.path` | Public fn | Return the relative directory path | `*const WorkDir` | `[]const u8` slice of `self.rel` | Borrowed; valid until `cleanup` |
| `WorkDir.join` | Public fn | Allocate `<rel>/<child>` path (caller frees) | child string | Heap-allocated concatenation | Caller owns returned `[]u8` |
| `WorkDir.createSubPath` | Public fn | Join a child path and `createDirPath` it | child string | Heap-allocated path; directory created | `errdefer` frees on failure |
| `WorkDir.writeFile` | Public fn | Write bytes to `<rel>/<rel_path>`, creating parent dirs | rel_path, data | File exists at path | Parent directories are created if absent |
| `WorkDir.readFile` | Public fn | Read full contents of `<rel>/<rel_path>` | rel_path, gpa | Heap-allocated `[]u8` (caller frees) | File is opened, fully read, closed |
| `WorkDir.cleanup` | Public fn | Best-effort recursive delete of `rel`; idempotent | — | `rel` tree removed from disk; `gpa.free(rel)` called; re-entrant calls are no-ops | `cleaned` guard prevents double-free |

### Helper functions

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `hasCode` | Private fn | Linear scan of `[]const diag.Diagnostic` for a code | diags slice, code | `bool` | No allocation |
| `expectCode` | Private fn | Assert that a specific diagnostic code is present | diags slice, code | `error.TestExpectedDiagnostic` if absent | Used by all graph-error tests |
| `collectRelFilesSorted` | Private fn | Recursively collect relative file paths under a root, sorted lexicographically | io, gpa, retain, root_rel, out ArrayList | Sorted `[]const u8` paths in `out` | Uses `walkCollect` + `std.mem.sort` |
| `walkCollect` | Private fn | Recursive DFS over `Io.Dir` collecting `.file` entries | dir, prefix, out | Appends paths to `out`; skips non-file, non-directory entries | `retain` allocator owns path strings |
| `expectDirsByteIdentical` | Private fn | Assert two directory trees are file-for-file, byte-for-byte identical | io, gpa, a_rel, b_rel | `error` if file lists differ or any content differs | File counts equal; names equal; bytes equal |
| `writeValidMultiPageSite` | Private fn | Write three fixture Markdown files: `index.md`, `guides/intro.md` (with Aside), `guides/intro-tips.md` (satellite) | work | Files on disk | Uses fixed content with known titles, tags, parent references |
| `writeLayout` | Private fn | Write `layouts/main.html` with given body | work, body | File on disk | — |

### Tests

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `harness: valid multi-page trunk/satellite IR build` | Integration test | Run full pipeline on 3-page fixture; verify pages, roles, parent links, JSON artifacts | `writeValidMultiPageSite` + `pipeline.run` | `result.ok`; 3 pages; freeze-sorted by id; `manifest.json` has `schemaVersion`; `graph.json` has `edges` | Graph frozen; page roles assigned; JSON emitted |
| `harness: invalid graph diagnostics` | Integration test (table-driven) | Run pipeline against 5 contract fixture content roots; assert each emits the expected diagnostic code | `docs/contracts/fixtures/{duplicate-ids,missing-parent,self-parent,cycles,satellite-of-satellite}/content` | `!result.ok`; specific `diag.Code` present | E_DUP_ID, E_PARENT_MISSING, E_PARENT_SELF, E_PARENT_CYCLE, E_PARENT_NOT_TRUNK |
| `harness: frontmatter syntax and UTF-8 failures` | Unit-ish test | Direct `frontmatter.parse` and `parser.parsePageSource` calls with invalid inputs | Unclosed fence, unknown key, bad tags, UTF-8 BOM, invalid UTF-8 bytes | Specific `diag.Code` or `error.Utf8Bom` / `error.InvalidUtf8` | E_FRONTMATTER, E_FRONTMATTER_VALUE, E_ENCODING |
| `harness: component tokenizer failures and valid rendering` | Unit-ish test | Parse valid Aside + render via apex/aside; parse unregistered component; parse unterminated Aside; parse invalid kind | Various body strings | Valid: HTML contains `<strong>`, `admonition--warning`, `id="w1"`, no raw `&lt;Aside>`; errors: diagnostic kinds present | `parser.parseBodySegmentsSimple`; `apex.render`; `aside.renderHtml` |
| `harness: empty page and large-but-bounded page` | Unit test | `parser.parsePageSource("")`; `apex.render("")`; large markdown up to `apex.test_large_md_bytes / 2` | Empty string; generated markdown | Empty: no errors, `body_md.len == 0`, `html.bytes.len == 0`; large: `html.bytes.len > 0`, contains `<h2>` | `apex.test_large_md_bytes` constant bounds CI test size |
| `harness: layout missing and duplicate content marker` | Unit test | `assemble.Layout.split` with missing and duplicate `&#123;&#123;content&#125;&#125;` markers, and a valid layout | Three layout strings | `error.MissingContentMarker`; `error.DuplicateContentMarker`; valid: `prefix == "<html>"`, `suffix == "</html>"` | Layout split invariants |
| `harness: RAG-only and normal build behavior` | Integration test | Run IR pipeline and RAG export on same content; assert IR writes `pageCount` to manifest but not RAG artifacts; RAG writes `catalog_meta.json` with `boris-rag` but not `manifest.json` | `writeValidMultiPageSite` + system seed doc | Separation of IR and RAG output namespaces | `pipeline.run` vs `scanner.scanFromCwd` + `rag.exportAll` |
| `harness: reproducible graph and RAG across two runs` | Integration test | Two IR pipeline runs → byte-identical `graph.json` and `manifest.json`; two RAG exports → byte-identical corpus trees; two compile runs → byte-identical dist trees | Same content, two independent invocations each | `expectEqualStrings` on JSON; `expectDirsByteIdentical` on RAG and dist | Determinism of serialisers and sort order |
| `harness: whiteboard reset isolates pages (no metadata/body reuse)` | Integration test | 3 pages with unique title/body markers; shared `doc_arena` reset with `free_all` after each page; titles promoted via `dupe` into PageDb | 3 Markdown files; loop with `defer _ = doc_arena.reset(.free_all)` | PageDb titles survive reset; each HTML file contains only its own markers; `doc_arena.queryCapacity() == 0` after last reset | Arena ownership boundary: page scratch vs long-lived PageDb |
| `harness: static fixture suite under test/fixtures` | Integration test | Run pipeline against `test/fixtures/valid-site/content` (3 pages) and `test/fixtures/empty-page/content` (1 page) | Committed fixture trees | `result.ok`; correct page counts | Static fixture contracts |
| `harness: discovery sort independent of creation order` | Integration test | Write 3 pages in reverse alphabetical order; run pipeline | `z-last.md`, `m-mid.md`, `a-first.md` created in that order | Frozen pages sorted alphabetically by id: `a-first`, `m-mid`, `z-last` | Deterministic path ordering independent of OS directory iteration order |
| `harness: compile aborts on bad layout before content` | Integration test | Write one content page; write layout without `&#123;&#123;content&#125;&#125;`; call `compile.compileSiteFromCwd` | `<html>missing marker</html>` as layout | `error.MissingContentMarker` returned | Layout validation precedes content rendering |
| `harness: static layout fixtures missing and duplicate` | Integration test | Read committed layout files from `test/fixtures/layouts/{missing-marker,duplicate-marker,ok}.html` | Committed fixture files | `error.MissingContentMarker`; `error.DuplicateContentMarker`; ok: `prefix.len > 0 && suffix.len > 0` | Static fixture contracts for layout parsing |
| `harness: utf8-bom fixture rejected on compiler frontmatter path` | Integration test | Run pipeline against `test/fixtures/utf8-bom/content` | Committed fixture | `!result.ok`; `E_ENCODING` diagnostic present | UTF-8 BOM rejection in pipeline frontmatter path |
| `harness: component-fail fixture parse has unregistered diagnostic` | Integration test | Read `test/fixtures/component-fail/content/bad-component.md`; call `parser.parsePageSource` | Committed fixture file | `parsed.hasErrors()` true; `.unregistered_component` diagnostic present | Static fixture contract for unknown component tag |


***

## Hostile-case walkthrough

`src/harness.zig` contains **no hostile cases** in the sense used for C-ABI adversarial testing. Every test invokes real production code paths with well-formed or intentionally invalid (but Zig-constructed) inputs. There is no C double, no mock allocator, no injected dirty pointer.

The cases below are the closest analogues — tests where invalid or edge-case inputs are injected at the Zig level:

### Unclosed frontmatter fence

**Injected behavior:**
`frontmatter.parse` is called with `"---\ntitle: X\n"` — a frontmatter block whose closing `---` is absent.

**Wrapper boundary exercised:**
`frontmatter.parse` fence-detection logic.

**Expected response:**
A diagnostic with code `E_FRONTMATTER` is appended; the function returns without panic.

**Forbidden unsafe response:**
Infinite loop or out-of-bounds read while scanning for the closing delimiter.

**Evidence strength:**
Directly demonstrated (if the file were on the build graph). Currently: contract-only — the test is not executed by any declared CI step.

**Residual gap:**
No assertion is made about the returned frontmatter struct's fields; only the diagnostic code is checked.

***

### Invalid UTF-8 bytes in frontmatter

**Injected behavior:**
`frontmatter.parse` is called with `[0xFF, 0xFE, ...]` inside a fenced block.

**Wrapper boundary exercised:**
UTF-8 validation gate in the frontmatter parser.

**Expected response:**
Diagnostic code `E_ENCODING` is emitted.

**Forbidden unsafe response:**
Passing invalid bytes to downstream systems; undefined behaviour in byte-access.

**Evidence strength:**
Contract-only (file not on build graph).

**Residual gap:**
The exact byte position of the diagnostic is not checked.

***

### UTF-8 BOM at page-source level

**Injected behavior:**
`parser.parsePageSource` is called with a BOM prefix (`0xEF 0xBB 0xBF`).

**Wrapper boundary exercised:**
The `parsePageSource` encoding gate, which is the first barrier before frontmatter extraction.

**Expected response:**
`error.Utf8Bom` returned.

**Forbidden unsafe response:**
Stripping the BOM silently and proceeding; returning success with corrupted data.

**Evidence strength:**
Contract-only (file not on build graph).

**Residual gap:**
Only the error value is checked; no assertion on whether the file was partially parsed.

***

### Whiteboard arena `free_all` isolation

**Injected behavior:**
A shared `doc_arena` is reset with `.free_all` after every page render in a three-page loop. Data that was allocated on the arena (parsed title slices) is checked for survival.

**Wrapper boundary exercised:**
The ownership boundary between `doc_arena` (scratch, reset per page) and `db.allocator()` (long-lived PageDb). The test requires that the caller explicitly `dupe` metadata into the long-lived allocator before the reset fires.

**Expected response:**
Promoted titles remain accessible via `promoted_titles[]` and `db.pages.items[]` after all three resets. Each output HTML file contains only its own content markers. `doc_arena.queryCapacity() == 0` after the last reset.

**Forbidden unsafe response:**
Storing an arena slice directly in PageDb (use-after-free on the next `free_all`); retaining an arena pointer in a rendered output buffer that is written to disk after the reset.

**Evidence strength:**
Contract-only (file not on build graph). The test structure is correct and would provide direct demonstration if executed.

**Residual gap:**
The test does not verify that intermediate HTML buffers (`html.items`) built from arena slices are fully flushed to disk before the `defer free_all` fires. It asserts post-hoc file content, which is sufficient but does not trace the exact flush order explicitly.

***

### Reproducibility (two independent IR/RAG/compile runs)

**Injected behavior:**
No adversarial injection; the test asserts a stability property by running the same pipeline twice.

**Wrapper boundary exercised:**
Serialiser sort order, timestamp-independence, and any global state that could differ between runs.

**Expected response:**
`graph.json`, `manifest.json`, and full dist tree are byte-identical across two runs.

**Forbidden unsafe response:**
Non-deterministic output due to hash-map iteration order, uninitialized padding in serialised structs, or filesystem-order-dependent discovery.

**Evidence strength:**
Contract-only (file not on build graph).

**Residual gap:**
The two runs occur within the same process invocation. Inter-process or inter-machine reproducibility is not tested.

***

## Control flow

The general test flow for every test in this file is:

```text
test declaration
    → WorkDir.create (unique temp directory under test-output/)
    → writeValidMultiPageSite / inline fixture writes / static fixture path
    → module under test (pipeline.run / frontmatter.parse / parser.parsePageSource
                         / apex.render / aside.renderHtml / assemble.Layout.split
                         / rag.exportAll / compile.compileSiteFromCwd)
    → result inspection (result.ok / result.pages / diagnostic codes / file contents)
    → std.testing assertions
    → defer WorkDir.cleanup() (best-effort directory deletion)
```

For tests that call `apex.render`, the call path through the real engine is:

```text
apex.render(md, &arena)
    → prepareMdForC(md)          — sentinel for empty; ptr+len for non-empty
    → lockRenderMutex()
    → c.apex_render(ptr, len, &out_ptr, &out_len, &apex_alloc)
        → zigAlloc callbacks from C (arena allocations)
        → zigFree callbacks from C (no-ops)
    → unlockRenderMutex()
    → mapRenderResult(rc, out_ptr, out_len)   — status before output read
    → Html{ .bytes = out_ptr[0..out_len] }
    → caller uses Html.bytes before doc_arena.reset(.free_all)
```

No hostile engine path is engaged by this file. All `apex.render` calls go through the real ApexMarkdown static libraries (assuming `zig build build-apex` has been run) with the `build_options.hostile_apex = false` flag.

***

## Relation to active test coverage

The tests in `src/harness.zig` overlap intentionally with tests in `src/hardening_test.zig`. The harness file's own doc comment states this explicitly and identifies the active replacements. The key structural difference is that `src/hardening_test.zig` is registered in `build.zig` and run under both `zig build test` and `zig build test-harness`, while `src/harness.zig` is not registered anywhere. Any test scenario in this file that is not duplicated in the active suite represents coverage that was available historically but may no longer be exercised.

The `WorkDir` struct is exported (`pub`) but there is no evidence in the repository that any other file currently imports it. If the active test suite imports `WorkDir` from this file, that would re-introduce a compilation dependency; no such import was found in `build.zig` or in the files inspected.

***
