---
title: "`src/hardening_test.zig` evidence and cases"
id: docs/boris/src/hardening_test/evidence-and-cases
parent: docs/boris/src/hardening_test
status: draft
tags: [boris, zig, source-reference, evidence, testing, integration]
---

# `src/hardening_test.zig` evidence and cases

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `WorkDir` struct | Helper | Per-test isolated temp directory with random hex suffix under `test-output/` | `gpa`, `Io`, label string | Directory created; cleanup on `defer work.cleanup()` | I/O isolation between tests; no cross-test artifact contamination |
| `WorkDir.create` | Helper fn | Creates `test-output/m10-{label}-{hex4}` directory | Allocator, Io, label | Returns `WorkDir` with `rel` path or propagates error | Disposable test artifact convention |
| `WorkDir.cleanup` | Helper fn | Deletes tree and frees `rel` | None | Tree deleted; `gpa.free` called | No test-output leakage between runs |
| `WorkDir.writeFile` | Helper fn | Writes a file at a relative path, creating parent dirs | Relative path, data | File exists at full path | Inline fixture creation without external fixture files |
| `WorkDir.readFile` | Helper fn | Reads entire file into caller-owned slice | Relative path, gpa | Allocated `[]u8` | File presence and readability assertions |
| `compareNamedFiles` | Helper fn | Byte-compares named files in two root directories | Io, gpa, two root paths, `[]const []const u8` names | `expectEqualSlices` for each name | Partial-tree determinism (named outputs only) |
| `treesByteIdentical` | Helper fn | Byte-compares entire file trees: sorted name sets must match, then each file byte-for-byte | Io, gpa, two root paths | `expectEqual` file counts; `expectEqualStrings` names; `expectEqualSlices` bytes | Full-tree determinism |
| `codesSet` | Helper fn | Extracts deduplicated, sorted set of error-severity `diag.Code` values from a diagnostic slice | `[]const diag.Diagnostic`, gpa | Sorted `[]diag.Code` owned slice | Diagnostic set comparison independent of count or order |
| `"hardening: IR dual-run byte identity"` | Test | Runs `pipeline.run` twice over `fixtures/content/valid` into separate dirs; compares `manifest.json` and `graph.json` | Real fixture tree | Both runs return `r.ok = true`; named files are byte-identical | IR output is deterministic across consecutive invocations |
| `"hardening: RAG dual-run byte identity"` | Test | Runs `rag.run` twice over the same fixture into separate dirs; compares entire output trees | Real fixture tree | Both `r.compile.ok = true`; full trees are byte-identical | RAG output is deterministic across consecutive invocations |
| `"hardening: IR and RAG match graph diagnostic categories"` | Test | Iterates six error-fixture trees; runs both `pipeline.run` and `rag.run`; compares deduplicated error code sets | Six `docs/contracts/fixtures/` subtrees | Both runs fail; `codesSet` results are equal; each set contains the expected code | Diagnostic convergence: IR and RAG share the same graph validation path |
| `"hardening: scanner creation order cannot affect IR bytes"` | Test | Writes three files in reverse alphabetical order; runs `pipeline.run` twice; asserts sorted page order and byte identity | Three inline `.md` files | `r.ok = true`; `r.pages.items[0..2]` IDs are `"a-first"`, `"m-mid"`, `"z-last"`; outputs byte-identical | Scanner sorts by path, not by discovery or creation order |
| `"hardening: duplicate id is diagnosed (not map-overwrite masked)"` | Test | Calls `graph_mod.validate` directly with three nodes, two sharing `id = "shared"` | In-memory `[]graph_mod.Node` | `EDUPLICATEID` diagnostic emitted; message contains `"alpha"` or `"beta"`; `nodes.len` remains 3 | Duplicate IDs are diagnosed and neither colliding node is silently dropped |
| `"hardening: output paths cannot escape roots"` | Test | Calls `identity.safeOutputRelativePath` and `identity.ragPagePath` with traversal inputs | `"../etc/passwd"`, `"a/../../x"`, `"/abs"`, `"../escape"`, `""`, and `"guides/intro"` | Traversal/absolute/empty inputs return specific errors; valid input returns `"guides/intro.html"` with no `..` | Path containment contract in `identity.zig` |
| `"hardening: invalid component fails IR with ECOMPONENT"` | Test | Writes a page with `&lt;Figure src="x">` (unregistered component); runs `pipeline.run` | Single inline `.md` fixture | `r.ok = false`; at least one diagnostic with code `.ECOMPONENT` | Unregistered components are diagnosed on the IR path |
| `"hardening: valid Aside passes IR and RAG :::kind export"` | Test | Writes a page with `&lt;Aside kind="tip" id="t1">`; runs both `pipeline.run` and `rag.run`; reads RAG page back | Single inline `.md` fixture | Both `ok`; emitted RAG page contains `:::tip{id="t1"}` and `"Drink water."`; does not contain literal `&lt;Aside` | Aside component is transformed on the RAG path; source tag is not passed through |
| `"hardening: Details include preserves IR and projects to HTML and RAG"` | Test | Writes an index page using ``&#123;&#123;include&#125;&#125;`` of a `&lt;Details>` component and a directly embedded `&lt;Details>`; writes a layout; runs IR, RAG, and HTML compile | Two inline fixtures + layout | IR JSON files contain no literal `"Details"`; HTML contains `<details class="details" id="more-1" open>` with correct summary HTML-escaping; RAG page contains `:::details{...}` syntax; no `&lt;Details` in outputs | Details component is not leaked as a raw tag into any output format; HTML-escaping is correct |
| `"hardening: Details HTML is stable across jobs and incremental builds"` | Test | Writes two pages with `&lt;Details>` components; compiles with `jobs=1`, `jobs=2`, and `incremental=true`; verifies incremental no-op and byte identity | Two inline fixtures + layout | `noop.pages_written = 0`; `index.html` and `other.html` are byte-identical across all three output directories | HTML rendering is stable under parallelism and incremental mode |
| `"hardening: experimental HTML renders Aside not raw tags"` | Test | Writes a page with `&lt;Aside kind="warning" id="w1">`; compiles to HTML; reads output | Single inline fixture + layout | `stats.pages_written = 1`; output contains `admonition--warning`, `id="w1"`, `"Careful"`; does not contain `&lt;Aside`; contains `<strong>world</strong>` | Aside renders to HTML admonition class; inline Markdown within the Aside body is rendered |
| `"hardening: component-fail fixture is ECOMPONENT on pipeline"` | Test | Runs `pipeline.run` over `test/fixtures/component-fail/content` | External fixture tree | `r.ok = false`; `.ECOMPONENT` diagnostic present | Component error reporting against a static fixture tree |
| `"hardening: aside API smoke"` | Test | Calls `aside.tokenizeBody` with a body containing one fenced code block (which should be ignored) and one real `&lt;Aside kind="note">` | Inline string | No errors; `r.asides.len = 1` | Code-fence suppression: Aside tags inside fenced blocks are not tokenized |

## Hostile-case walkthrough

**Note:** `hardening_test.zig` does not inject hostile or malformed C behavior; it has no C double and no ABI boundary manipulation. The "hostile cases" in this file are adversarial inputs to the Boris Zig subsystems themselves — malformed IDs, traversal paths, unregistered component tags, and structurally invalid content trees. Each subsection below follows the required format adapted to this context.

***

### Duplicate ID with shared key across two files

**Injected behavior:**
`graph_mod.validate` is called with a manually constructed `[]graph_mod.Node` slice containing two nodes that share `id = "shared"` but have different `source_path` values (`"alpha.md"` and `"beta.md"`), plus a third node with a distinct ID.

**Wrapper boundary exercised:**
`graph_mod.validate`'s ID-uniqueness check and diagnostic emission. The test verifies that the implementation does not use a plain map overwrite (which would silently drop one node and emit no diagnostic).

**Expected response:**
At least one `EDUPLICATEID` diagnostic is emitted. The diagnostic message must reference at least one of `"alpha"` or `"beta"` so neither colliding source path is invisible in the error output. The `nodes` slice length remains 3 after validation — nodes are not removed from the slice before diagnostic emission.

**Forbidden unsafe response:**
Silently overwriting the first node with the second in an ID map, discarding one path from the diagnostic message, or mutating `nodes.len` before emitting the diagnostic.

**Evidence strength:**
Directly demonstrated — the test calls `graph_mod.validate` synchronously and inspects the returned diagnostic list and the slice length.

**Residual gap:**
The test does not verify the exact wording or structured fields of the diagnostic beyond the string-search for path fragments. It does not test three-way collisions (three nodes with the same ID), or collisions between a trunk and a satellite. It also does not verify that the duplicate IDs are correctly reflected in the emitted `graph.json`.

***

### Output path traversal inputs

**Injected behavior:**
`identity.safeOutputRelativePath` is called with five adversarial strings: `"../etc/passwd"` (leading traversal), `"a/../../x"` (embedded traversal), `"/abs"` (absolute path), `""` (empty ID), and `"../escape"` routed through `identity.ragPagePath`. A benign input `"guides/intro"` is also tested.

**Wrapper boundary exercised:**
`identity.safeOutputRelativePath` and `identity.ragPagePath`, which are the sole entry points for converting a page ID to an on-disk relative path. These functions are called by the pipeline and RAG emitters before any file write; they are the containment boundary between user-controlled IDs and the file system.

**Expected response:**

- `"../etc/passwd"` → `error.IllegalSegment`
- `"a/../../x"` → `error.IllegalSegment`
- `"/abs"` → `error.AbsolutePath`
- `"../escape"` (via `ragPagePath`) → `error.IllegalSegment`
- `""` → `error.EmptyId`
- `"guides/intro"` → success, returns `"guides/intro.html"`, contains no `..`

**Forbidden unsafe response:**
Returning a path string that contains `..` components, that begins with `/`, or that is empty. Passing any such string to a file-write function would be undefined behavior at the OS level.

**Evidence strength:**
Directly demonstrated — each input is tested with `std.testing.expectError` or `std.testing.expect`.

**Residual gap:**
The test does not exercise null bytes, Windows-style backslash separators, excessively long IDs, or IDs containing only whitespace. It does not verify that the containing pipeline functions (`pipeline.run`, `rag.run`) propagate these errors as build failures rather than panics. The RAG path is exercised only for the `"../escape"` input; multi-segment RAG traversal cases are not covered.

***

### Scanner file creation order

**Injected behavior:**
Three Markdown files are written to a temporary directory in reverse alphabetical order (`z-last.md`, `m-mid.md`, `a-first.md`). This simulates a file system that returns directory entries in creation order rather than alphabetical order.

**Wrapper boundary exercised:**
`scanner.zig`'s enumeration and sorting logic, as invoked by `pipeline.run`. The contract requires that page ordering in the emitted manifest is stable and path-derived, not dependent on `readdir` order.

**Expected response:**
`r.pages.items[^1_0].id = "a-first"`, `r.pages.items[^1_1].id = "m-mid"`, `r.pages.items[^1_2].id = "z-last"`. A second run over the same directory produces byte-identical `manifest.json` and `graph.json`.

**Forbidden unsafe response:**
Page ordering that varies between runs, or that reflects the order in which files were created or discovered by the OS rather than their sorted path order.

**Evidence strength:**
Directly demonstrated — the test asserts individual `pages.items[i].id` values and byte-compares the two output directories.

**Residual gap:**
The test runs both pipeline invocations sequentially on the same host within the same process; it does not verify ordering across different operating systems or file systems with different `readdir` conventions. It also does not test directories with more than three entries, Unicode filenames, or symlinks.

***

### IR and RAG graph diagnostic convergence

**Injected behavior:**
Six error-condition fixture trees from `docs/contracts/fixtures/` are used: `duplicate-ids`, `missing-parent`, `self-parent`, `cycles`, `satellite-of-satellite`, and `longer-cycle`. Each tree is a static set of Markdown files whose content reliably triggers the associated graph error.

**Wrapper boundary exercised:**
The graph validation code path reached through `pipeline.run` (IR path) versus `rag.run` (RAG path). Both must call the same or equivalent validation and produce diagnostics with the same error codes for the same inputs.

**Expected response:**
Both runs return `ok = false`. The deduplicated, sorted sets of error-severity `diag.Code` values from both diagnostic lists are equal. The set for each fixture contains at least the expected code (`.EDUPLICATEID`, `.EPARENTMISSING`, `.EPARENTSELF`, `.EPARENTCYCLE`, `.EPARENTNOTTRUNK`).

**Forbidden unsafe response:**
IR and RAG producing different error code sets for the same input; either pipeline masking a graph error and returning `ok = true`; or either pipeline panicking rather than returning a diagnostic.

**Evidence strength:**
Directly demonstrated — the test iterates all six fixtures and uses `expectEqualSlices(diag.Code, ir_codes, rag_codes)` followed by a linear scan for the expected code.

**Residual gap:**
The test checks code sets but not diagnostic counts, messages, source-path annotations, or severity distributions within each fixture. It does not test mixed-error trees (e.g., a tree with both a duplicate ID and a cycle). The fixture files themselves are static and would need to be updated manually if new error codes are introduced.

***

### Unregistered component tag in pipeline

**Injected behavior:**
A Markdown file containing `&lt;Figure src="x">nope&lt;/Figure>` is written inline; the `Figure` component is not registered in Boris's component registry. `pipeline.run` is then called on this content tree.

**Wrapper boundary exercised:**
The component validation step within `pipeline.run`, which must reject unrecognized component names and emit `ECOMPONENT` rather than passing the tag through to the IR or treating it as raw HTML.

**Expected response:**
`r.ok = false`; at least one diagnostic in `r.diagnostics.items` has code `.ECOMPONENT`.

**Forbidden unsafe response:**
Treating the unknown component as raw HTML passthrough; silently dropping the component and emitting no diagnostic; or returning `ok = true`.

**Evidence strength:**
Directly demonstrated — both the `ok` flag and the diagnostic code are checked.

**Residual gap:**
The test uses a single unregistered component in a simple document; it does not test multiple unregistered components, unregistered components nested inside registered ones, or unregistered components in included files. It also does not verify the diagnostic message content or the source location reported.

***

### Aside tag in fenced code block not tokenized

**Injected behavior:**
`aside.tokenizeBody` is called with a body containing a fenced code block that encloses a syntactically valid `&lt;Aside kind="tip">` tag, followed by a real `&lt;Aside kind="note">` outside the fence.

**Wrapper boundary exercised:**
`aside.tokenizeBody`'s code-fence suppression logic, which must not treat Aside tags inside fenced blocks as component instances.

**Expected response:**
`r.hasErrors() = false`; `r.asides.len = 1` (only the real Aside outside the fence is counted).

**Forbidden unsafe response:**
Counting both Asides (returning `len = 2`); or treating the fenced content as a component and producing a spurious entry.

**Evidence strength:**
Directly demonstrated — `expectEqual(@as(usize, 1), r.asides.len)` is asserted.

**Residual gap:**
This is a smoke test of the public API, not a comprehensive tokenizer test. Detailed tokenizer edge cases are documented as living in `aside.zig`'s own test blocks. The file does not test nested fences, fences without a closing delimiter, or `&lt;Aside>` tags that span fence boundaries.

***

### Details HTML-escaping and cross-format rendering

**Injected behavior:**
A `&lt;Details summary="Read <this> & that" id="more-1" open="true">` component is embedded via ``&#123;&#123;include&#125;&#125;`` in a page. This summary string contains characters requiring HTML entity escaping (`<`, `>`, `&`).

**Wrapper boundary exercised:**
The HTML compile path's attribute serialization for the `<summary>` element, which must not emit unescaped `<`, `>`, or `&` into the HTML output.

**Expected response:**
The emitted HTML contains `<summary>Read &lt;this&gt; &amp; that</summary>`. The raw `&lt;Details` tag is absent from HTML, RAG, and IR JSON outputs. The RAG output contains `:::details{summary="RAG details" id="rag-1"}` for the directly embedded Details component.

**Forbidden unsafe response:**
Emitting `<summary>Read <this> & that</summary>` (unescaped); passing `&lt;Details` through to any output format; or emitting the HTML attributes in a different order from the canonical form.

**Evidence strength:**
Directly demonstrated — the test reads the emitted files back and uses `std.mem.indexOf` to assert both the presence of the escaped form and the absence of the raw tag.

**Residual gap:**
The test checks the escaped form by substring match, not by full HTML parse; a partial match could in principle pass with malformed surrounding context. It does not test quotes inside attribute values, `Details` with no `id`, or `Details` whose `summary` contains only special characters. The ordering of HTML attributes in the emitted `<details>` tag is implicitly verified by the exact-string search but not stated as a contract.

## Control flow

The general flow for every test in the file is:

```text
test declaration
    → WorkDir.create  (allocate temp directory under test-output/)
    → WorkDir.writeFile (optional: write inline fixture files)
    → <subsystem>.run or direct validate/tokenize call
        → pipeline.run / rag.run / compile.compileHtmlSite
            → scanner.zig  (enumerate, sort files)
            → parser / frontmatter (extract metadata)
            → graph_mod.validate (check IDs, parents, cycles)
            → aside / compile (component validation and transformation)
            → ir_emit / rag_emit (serialize JSON or Markdown)
            → Apex (real engine via vendor/apex/apex.c) [for HTML compile path]
        → returns Result with ok flag, diagnostics, pages
    → Assertions (expectEqual, expectEqualSlices, expectEqualStrings,
                  expectError, std.mem.indexOf)
    → WorkDir.cleanup  (delete tree, free rel)
```

For the byte-identity tests the `<subsystem>.run` step is executed twice and `compareNamedFiles` or `treesByteIdentical` replaces the assertion step:

```text
run A → out_a/
run B → out_b/
compareNamedFiles / treesByteIdentical
    → open dir_a, dir_b
    → for each name: read both files → expectEqualSlices
```

For the graph-diagnostic convergence test a loop over six fixture descriptors drives both pipelines and compares their `codesSet` outputs:

```text
for each fixture { root, expected_code }:
    pipeline.run(root) → ir_result (ok=false)
    rag.run(root)      → rag_result (ok=false)
    codesSet(ir_result.diagnostics) → ir_codes
    codesSet(rag_result.diagnostics) → rag_codes
    expectEqualSlices(ir_codes, rag_codes)
    linear scan: assert expected_code ∈ ir_codes
```
