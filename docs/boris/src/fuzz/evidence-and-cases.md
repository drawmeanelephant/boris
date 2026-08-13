---
title: "`src/fuzz.zig` evidence and cases"
id: docs/boris/src/fuzz/evidence-and-cases
parent: docs/boris/src/fuzz
status: draft
tags: [boris, zig, source-reference, evidence, fuzz]
---

# `src/fuzz.zig` evidence and cases

## Test harness construction

`fuzz.zig` is the root source file of the `fuzz_mod` module in `build.zig`:

```zig
const fuzz_mod = b.createModule(.{
    .root_source_file = b.path("src/fuzz.zig"),
    .target = target,
    .optimize = optimize,
});
linkOliver(fuzz_mod, oliver_mod);     // pinned Oliver module via render_mod seam
```

`linkOliver(fuzz_mod, oliver_mod)` wires the pinned Oliver dependency (exact revision in `build.zig.zon`; see `docs/contracts/oliver-renderer.md`) into the test binary through `render_mod`. There is no C adapter, no static-archive build step, and no hostile double — Oliver is consumed as a pure Zig module exactly as production does.

The `fuzz.zig` module imports five production modules directly via `@import`:

- `parser.zig` — used in `runFrontmatterFuzz`
- `aside.zig` — used in `runComponentFuzz`
- `render.zig` — used in `runRenderFuzz`
- `graph.zig` — used in `runGraphTopologyFuzz` and `referenceCheck`
- `diag.zig` — used for `diag.Diagnostic`, `diag.Code`, and `diag.countErrors`

The test binary is compiled as part of `zig build test` (the default step). There is no separate opt-in step for `fuzz.zig`. The module is listed alongside all other test steps in the `test_step.dependOn` chain.

The production binary cannot accidentally link the fuzz module: `fuzz_mod` is only referenced by `fuzz_tests` (a test executable), not by the `exe` artifact or any library used by `exe`.

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `runFrontmatterFuzz(seed, iters)` | Public fn | No-panic property over arbitrary byte payloads for the product frontmatter parser | PRNG seeded with `seed ^ 0` (no XOR); `max_input_bytes=512`; structured templates every 5th iteration | `parser.parse` returns without panicking; successful results preserve the body offset/slice invariant | Product parser must never panic on any byte content |
| `runComponentFuzz(seed, iters)` | Public fn | No-panic on valid UTF-8; clean error on invalid UTF-8 for component tokenizer | PRNG seeded `seed ^ 0xC0C0`; valid UTF-8 filled via `fillValidUtf8`; structured templates every 4th iteration; explicit `[0xFF, 0xFE, ...]` test after loop | No panic, no `error.InvalidUtf8` on valid UTF-8 paths; `error.InvalidUtf8` on explicit invalid sequence | `aside.tokenizeBody` must reject invalid UTF-8 cleanly |
| `runRenderFuzz(seed, iters)` | Public fn | No-crash property for the Oliver-backed render seam over bounded random bytes | PRNG seeded `seed ^ 0xA9E5`; `max_input_bytes=512`; structured Markdown every 3rd iteration; 128 iterations of `render.render` | `render.render` returns or yields an error in the documented set; no panic | `render.render` must not crash on arbitrary bounded bytes |
| `runGraphTopologyFuzz(seed, iters)` | Public fn | Category-level agreement between production `graph.validate` and independent reference checker | PRNG seeded `seed ^ 0x6BA9`; 200 random topologies of 1–12 nodes; 6 topology modes including dup, star, chain, cycle, self-parent, missing | `expectEqual` assertions on five flag pairs; clean graphs produce zero diagnostics | `graph.validate` must agree with independent oracle on all five error categories |
| `referenceCheck(nodes)` | Public fn | Independent O(n²) reference oracle for graph topology | `[]const graph_mod.Node` slice | Returns `RefProblems` struct with five boolean flags | No dependency on `graph.zig` internals; uses only `mem.eql` string comparisons |
| `test "fuzz: frontmatter parser bounded (deterministic seed)"` | Test | Invokes `runFrontmatterFuzz` at `default_seed` and `frontmatter_iters=256` | Fixed constants | Must not error | Same as `runFrontmatterFuzz` |
| `test "fuzz: component tokenizer bounded (deterministic seed)"` | Test | Invokes `runComponentFuzz` at `default_seed` and `component_iters=256` | Fixed constants | Must not error | Same as `runComponentFuzz` |
| `test "fuzz: renderer bounded no-crash (deterministic seed)"` | Test | Invokes `runRenderFuzz` at `default_seed` and `render_iters=128` | Fixed constants | Must not error | Same as `runRenderFuzz` |
| `test "fuzz: random graph topology agrees with reference checker"` | Test | Invokes `runGraphTopologyFuzz` at `default_seed` and `graph_iters=200` | Fixed constants | Must not error | Same as `runGraphTopologyFuzz` |
| `test "fuzz: reference checker known cases"` | Test | Validates `referenceCheck` against six hand-constructed named cases | Hardcoded node arrays for: valid trunk+satellite, self-parent, missing parent, two-node cycle, satellite-of-satellite, duplicate ids | Each case asserts exactly the expected flag(s) are set | Reference oracle correctness |
| `test "fuzz: seeds are stable documented constants"` | Test | Asserts bound constants are within documented safe limits | Inline literal checks | `default_seed == 0xB0B15_F027`, `frontmatter_iters > 0`, `max_input_bytes <= 4096`, `max_graph_nodes <= 32` | Documentation contract on iteration and size bounds |
| `structuredFrontmatter(random, buf)` | Private fn | Produces semi-valid or deliberately corrupted frontmatter fence payloads | 9 templates; random byte flips | Returns a `[]const u8` slice into `buf` | Input diversity for frontmatter fuzzer |
| `fillValidUtf8(random, buf)` | Private fn | Fills a byte slice with syntactically valid UTF-8 | ASCII + 2-byte + 3-byte sequences | No invalid multi-byte sequences; no truncated sequences at end | Valid UTF-8 contract for tokenizer fuzzer |
| `structuredComponent(random, buf)` | Private fn | Produces realistic `&lt;Aside>` component markup variants | 9 templates including unterminated, nested, mid-line closing, unknown kind; occasional ASCII-range byte corruption | Returns a `[]const u8` slice into `buf` | Input diversity for component tokenizer fuzzer |
| `generateRandomGraph(random, id_pool, nodes, path_buf, gpa)` | Private fn | Populates a `[]graph_mod.Node` slice with one of 6 topology modes | Pool of 12 static string ids (`"n0"`–`"n11"`); `mode` selected randomly; optional `force_dup` | Nodes have `source_path` allocated from `gpa` (freed per-iteration by caller) | Topology diversity for graph fuzzer |
| `productionProblems(diags)` | Private fn | Maps `diag.Diagnostic` slice to `RefProblems` struct using `diag.Code` tags | `[]const diag.Diagnostic` | `RefProblems` with flags set for any diagnostic with matching code | Adapter between production diagnostic output and reference oracle format |
| `findId(nodes, id)` | Private fn | Linear id lookup returning optional index | Used by `referenceCheck` cycle walk | `?usize` | Reference oracle helper — independent of `graph.zig`'s `buildIdIndex` |

## Hostile-case walkthrough

### Random byte payloads to `render.render` — no-crash property

**Injected behavior:**
128 random byte sequences of length 0–512 (inclusive) are passed to `render.render`, each with a freshly reset arena. Every 3rd iteration substitutes a fixed structured Markdown string (`# H\n\n**b** and *i*\n`) so the no-crash property also covers real parsing paths.

**Seam boundary exercised:**
The full `render.render` call path: `oliver.parse` (Markdown options: footnotes, definition lists, heading attributes) → `oliver.html.render` (heading ids + footnotes section) into a Whiteboard arena, returning `Html.bytes` as a view of arena memory.

**Expected response:**
Any of: successful `Html`; `error.OutOfMemory`; `error.InputTooLarge`; `error.WriteFailed`; `error.NoSpaceLeft`. No panic and no crash.

**Forbidden unsafe response:**
A panic from arbitrary bytes, or a returned `Html.bytes` slice that is not a valid view into arena memory.

**Evidence strength:**
Partial coverage — the no-crash property is demonstrated for 128 bounded random inputs. The property is not proven for all possible inputs or for inputs larger than 512 bytes.

**Residual gap:**
Random bytes rarely produce valid Markdown that exercises complex Oliver paths (footnotes, definition lists, tables). Output correctness for those constructs is covered by the structured fixtures in `src/render.zig` and the Oliver contract fixtures (`docs/contracts/oliver-renderer.md`), not by `fuzz.zig`.

***

### Graph topology with two-node cycle

**Injected behavior:**
`generateRandomGraph` mode 3 sets `nodes[^1_0].parent = nodes[^1_1].id` and `nodes[^1_1].parent = nodes[^1_0].id`, creating a mutual parent cycle when n ≥ 2 and no forced duplicate IDs.

**Wrapper boundary exercised:**
`graph.validate` → `validateTopology` DFS cycle detection; `referenceCheck` walk-based cycle detection. Both must agree.

**Expected response:**
`ref.cycle == true`; `prod.cycle == true` (assertion in `runGraphTopologyFuzz`: `if ref.cycle and !ref.dup_id → expect prod.cycle or prod.not_trunk or prod.self_parent`).

**Forbidden unsafe response:**
`graph.validate` entering an infinite DFS loop; `referenceCheck` walking beyond `nodes.len + 1` steps without setting `p.cycle`; either returning a false-negative that causes the agreement assertion to fire.

**Evidence strength:**
Directly demonstrated across 200 random topology iterations (though mode 3 is selected with probability 1/6, so it appears roughly 33 times per run of 200 iterations).

**Residual gap:**
Longer cycles (3+ nodes) are not directly targeted by a mode; they would require a chain topology with a back-edge, which is not generated. Three-node and longer cycles are tested in `graph.zig`'s own named tests but not exercised by the fuzz generator.

***

### Graph topology with satellite-of-satellite (chain mode)

**Injected behavior:**
Mode 2 creates `0←1←2←…` — each node points at the previous. Node 2's parent (node 1) is itself a satellite (has a parent), triggering `EPARENTNOTTRUNK`.

**Wrapper boundary exercised:**
`validateTopology`'s satellite-of-satellite pass; `referenceCheck`'s `not_trunk` detection (checks whether a candidate parent itself has a non-null `parent` field).

**Expected response:**
`ref.not_trunk == true` for any chain of depth ≥ 2; `prod.not_trunk == true` (assertion: `if ref.not_trunk and !ref.cycle → expect prod.not_trunk`).

**Forbidden unsafe response:**
`graph.validate` silently accepting a multi-hop chain without emitting `EPARENTNOTTRUNK`; `referenceCheck` failing to detect the condition.

**Evidence strength:**
Directly demonstrated — mode 2 fires with probability ~1/6, and `ref.not_trunk` is set whenever the chain depth is ≥ 2 (i.e., n ≥ 3, which is approximately 10/12 of the time given uniform n in 1–12).

**Residual gap:**
The agreement assertion for `not_trunk` in the presence of a simultaneous cycle uses a relaxed form: `if prod.not_trunk → expect ref.not_trunk or ref.cycle`. This acknowledges that production may report `EPARENTNOTTRUNK` for a cycle-involving chain before the DFS reaches the cycle, and the reference checker may flag the same topology as a cycle. The exact code emitted in these mixed cases is not fully specified.

***

### Forced duplicate ID

**Injected behavior:**
`generateRandomGraph` sets `force_dup = true` with probability 1/8 when n ≥ 2. The last node receives the same id as the first node from `id_pool`.

**Wrapper boundary exercised:**
`graph.diagnoseDuplicateIds` (called by `graph.validate`); `referenceCheck`'s O(n²) duplicate scan.

**Expected response:**
`ref.dup_id == true`; `prod.dup_id == true` (direct `expectEqual` assertion).

**Forbidden unsafe response:**
`diagnoseDuplicateIds` emitting no `EDUPLICATEID` diagnostic when two nodes share an id; `referenceCheck` false-negative.

**Evidence strength:**
Directly demonstrated — the forced-dup path is selected unconditionally when the random roll is 0 out of 0–7.

**Residual gap:**
Case-only id collisions (`EINVALIDPATH`) are not generated by `generateRandomGraph`. Those are tested in `graph.zig`'s own `diagnoseDuplicateIds` tests.

***

### Explicit invalid UTF-8 to component tokenizer

**Injected behavior:**
After the main fuzz loop, `runComponentFuzz` passes `[0xFF, 0xFE, '<', 'A', 's', 'i', 'd', 'e', '>']` directly to `aside.tokenizeBody`. The `0xFF 0xFE` prefix is unambiguously invalid UTF-8.

**Wrapper boundary exercised:**
`aside.tokenizeBody`'s UTF-8 validation gate (the function is documented as requiring valid UTF-8).

**Expected response:**
`error.InvalidUtf8` via `expectError`.

**Forbidden unsafe response:**
Panic; successful return of tokens derived from bytes interpreted as if valid UTF-8; silent byte-skipping that produces a structurally incorrect token stream.

**Evidence strength:**
Directly demonstrated for this one hardcoded sequence.

**Residual gap:**
Only one invalid sequence is tested. Other forms of invalid UTF-8 (truncated multi-byte sequences, overlong encodings, surrogates) are not explicitly covered. The `fillValidUtf8` generator never produces invalid UTF-8 by construction, so the free-form random path never hits this error branch.

***

### Frontmatter parser no-panic and body-boundary invariant

**Injected behavior:**
All frontmatter fuzz iterations, including the most corrupted templates (e.g., unclosed fences + random byte flips), are run through the product `parser.parse`.

**Wrapper boundary exercised:**
The parser contract: arbitrary bounded bytes must return a result or diagnostic without panicking, and a successful result's body slice must begin at its reported offset.

**Expected response:**
For a successful parse, `result.doc.body` equals `payload[result.doc.body_offset..]` and `body_offset <= payload.len`.

**Forbidden unsafe response:**
Returning a body slice outside the source buffer or panicking on malformed bytes.

**Evidence strength:**
Structurally checked — the parser is called on every iteration and the boundary assertion fires on every successful parse, including structured templates.

**Residual gap:**
The test does not assert a specific diagnostic category for each generated input or cover sources above the 512-byte fuzz payload bound; focused parser tests cover normative categories and limits.

## Control flow

### Frontmatter fuzz iteration

```text
test "fuzz: frontmatter parser bounded"
    → runFrontmatterFuzz(default_seed, 256)
        → structuredFrontmatter(random, &buf)  [every 5th iter]
          OR random.bytes(buf[0..n])           [otherwise]
        → parser.parse(payload)
            → [product parser: no panic contract]
            → returns ParseResult
        → successful result: expect body_offset/body slice agreement
```


### Component tokenizer fuzz iteration

```text
test "fuzz: component tokenizer bounded"
    → runComponentFuzz(default_seed, 256)
        → arena.reset(.free_all)                    [per iteration]
        → structuredComponent(random, &buf)         [every 4th iter]
          OR fillValidUtf8(random, buf[0..n])        [otherwise]
        → aside.tokenizeBody(payload, arena.allocator())
            → [tokenizer: no panic on valid UTF-8]
            → must not return error.InvalidUtf8 on valid UTF-8 paths
        → [post-loop] tokenizeBody([0xFF, 0xFE, ...], arena.allocator())
            → expectError(error.InvalidUtf8, ...)
```


### Renderer fuzz

```text
test "fuzz: renderer bounded no-crash (deterministic seed)"
    → runRenderFuzz(default_seed, 128)
        → [loop: 128 iters]
            → arena.reset(.free_all)
            → random.bytes(buf[0..n])  OR  structured markdown [every 3rd iter]
            → render.render(md, &arena)
                → oliver.parse(a, md, .markdown, options)
                    → [Oliver: source bytes → typed document]
                → oliver.html.render(a, &aw.writer, &result.document, render_options)
                    → [Oliver: typed document → deterministic HTML]
                → returns Html{ .bytes = arena-backed view }
            → [accepted: any non-panic result, including the documented
               error set: OutOfMemory | InputTooLarge | WriteFailed | NoSpaceLeft]
```


### Graph topology fuzz iteration

```text
test "fuzz: random graph topology agrees with reference checker"
    → runGraphTopologyFuzz(default_seed, 200)
        → generateRandomGraph(random, id_pool, nodes[0..n], path_buf, gpa)
            → mode ∈ {0=all-trunk, 1=star, 2=chain, 3=two-cycle, 4=self, 5+=missing}
            → optional force_dup
        → referenceCheck(nodes[0..n])       ← independent O(n²) oracle
            → returns RefProblems{dup_id, self_parent, missing_parent, not_trunk, cycle}
        → @memcpy(work[0..n], nodes[0..n])  ← isolate production call
        → graph_mod.validate(gpa, retain, work[0..n], &diags)
            → diagnoseDuplicateIds(...)
            → validateTopology(...)
                → buildIdIndex (O(n) hash map)
                → classify nodes (self/missing)
                → satellite-of-satellite pass
                → DFS gray-set cycle detection
        → productionProblems(diags.items)   ← maps diag.Code → RefProblems
        → expectEqual(ref.dup_id, prod.dup_id)
        → expectEqual(ref.self_parent, prod.self_parent)
        → expectEqual(ref.missing_parent, prod.missing_parent)
        → [not_trunk agreement: relaxed for cycle interactions]
        → [cycle agreement: relaxed for not_trunk interactions]
        → if !ref.any(): expect !prod.any() and zero errors
```
