---
title: "`src/fuzz.zig` surface and execution"
id: docs/boris/src/fuzz/surface-and-execution
parent: docs/boris/src/fuzz
status: draft
tags: [boris, zig, source-reference, surface, fuzz]
---

# `src/fuzz.zig` surface and execution

## Threat model

### Frontmatter parser — no-panic on arbitrary bytes

The frontmatter parser (`frontmatter.parse`) receives caller-supplied byte slices that in production are file contents read from disk, which can be arbitrarily malformed. Threat categories exercised:

- **Binary garbage inputs** (random bytes 0–255): verifies that the parser never panics or enters an infinite loop regardless of byte content.
- **Structured-but-corrupt templates**: nine semi-valid YAML fence patterns (unclosed fences, invalid status values, malformed tag lists, parent pointing to `..`) are selected randomly and then a random number of bytes (1–4) are flipped to arbitrary values. This forces the parser through realistic near-miss paths.
- **Empty input**: empty slices are a normal boundary case for files without frontmatter.
- **Diagnostic explosion**: asserts `diags.items.len < 10_000` after each iteration, preventing a pathological grammar from generating an unbounded number of error records.

Category **not** exercised: assertion that specific diagnostics are emitted for specific inputs; correctness of the returned parse result.

### Component tokenizer — no-panic on valid UTF-8; clean error on invalid UTF-8

The `aside.tokenizeBody` function requires valid UTF-8. Threat categories exercised:

- **Arbitrary valid UTF-8**: a purpose-built `fillValidUtf8` generator emits ASCII, 2-byte (U+00A0–U+07FF range, conservative), and 3-byte sequences (conservative E2-prefix), verifying no panic on any valid Unicode content.
- **Structured component templates**: nine templates including nested `&lt;Aside>`, unterminated components, mid-line closing tags, and unknown `kind` attributes are randomly selected and occasionally byte-corrupted (keeping ASCII range to avoid accidental UTF-8 invalidity).
- **Explicit invalid UTF-8**: a hardcoded `[0xFF, 0xFE, '<', 'A', 's', 'i', 'd', 'e', '>']` sequence asserts `error.InvalidUtf8` is returned, not a panic or a successful parse.

Category **not** exercised: semantic correctness of tokens; that valid-UTF-8 inputs produce structurally sound token output.

### Apex wrapper — pointer/length contract invariants and no-crash

The `apex.prepareMdForC` and `apex.mapRenderResult` functions are the Zig-side gates that prevent illegal pointer/length combinations from reaching or returning from the C engine. Threat categories exercised:

- **Empty input pointer contract**: asserts that `prepareMdForC(&.{})` returns a non-null sentinel pointer with length 0. The C ABI requires a non-null `md` even for zero-length input.
- **Non-zero status with dirty outputs via `mapRenderResult`**: three direct `mapRenderResult` calls simulate a hostile engine: `rc=2` (OOM) with a non-null poison pointer and length 99 → must return `error.OutOfMemory`; `rc=1` (ARGS) with a non-null poison pointer and length 99 → must return `error.RenderFailed`; `rc=0` (OK) with a null pointer and length 5 → must return `error.RenderFailed` (null+nonzero length ABI violation).
- **No-crash on bounded random payloads**: 128 iterations of `apex.render` with random byte inputs of 0–512 bytes, accepting `error.OutOfMemory` and `error.RenderFailed` as valid outcomes alongside success.
- **Non-empty input pointer and length preservation**: asserts `prep.ptr == md.ptr` and `prep.len == md.len` for each random input.

Category **not** exercised: behavior of the real ApexMarkdown C implementation on adversarial inputs (only the Zig wrapper contracts are verified here); allocator callback exhaustion; pointer-retention after return; reentrancy.

### Graph topology — reference-checker agreement

`graph.validate` performs duplicate-id detection, self-parent rejection, missing-parent detection, satellite-of-satellite rejection, and DFS cycle detection, emitting typed diagnostic codes. Threat categories exercised:

- **Duplicate IDs** (`EDUPLICATEID`): forced by setting `force_dup = true` with probability 1/8 (when n ≥ 2), giving the last node the same id as the first.
- **Star topology** (mode 1): all nodes point at node 0 — valid if unique IDs.
- **Chain topology** (mode 2): `0←1←2←…` — nodes beyond depth 1 trigger `EPARENTNOTTRUNK`.
- **Two-node cycle** (mode 3): mutual parent pointers trigger `EPARENTCYCLE`.
- **Self-parent** (mode 4): one node's `parent` is set to its own id → `EPARENTSELF`.
- **Missing parent** (mode 5+): one node's `parent` is set to `"does-not-exist"` → `EPARENTMISSING`.
- **All-trunk** (mode 0): no parents set → both sides should report no problems.

Category **not** exercised: topologies with more than 12 nodes; case-only id collisions (`EINVALIDPATH`); multi-hop chains deeper than 2 levels as a standalone case; the `freeze` step after `validate`.
