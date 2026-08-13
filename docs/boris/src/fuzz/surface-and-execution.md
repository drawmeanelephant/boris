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

The product frontmatter parser (`parser.parse`) receives caller-supplied byte slices that in production are file contents read from disk, which can be arbitrarily malformed. Threat categories exercised:

- **Binary garbage inputs** (random bytes 0–255): verifies that the parser never panics or enters an infinite loop regardless of byte content.
- **Structured-but-corrupt templates**: nine semi-valid frontmatter fence patterns (unclosed fences, invalid status values, malformed tag lists, parent pointing to `..`) are selected randomly and then a random number of bytes (1–4) are flipped to arbitrary values. This forces the parser through realistic near-miss paths.
- **Empty input**: empty slices are a normal boundary case for files without frontmatter.
- **Successful body boundary**: asserts that successful results report a body offset within the source and return the exact suffix from that offset.

Category **not** exercised: assertion that specific diagnostics are emitted for specific inputs; focused tests in `src/parser.zig` cover those normative cases.

### Component tokenizer — no-panic on valid UTF-8; clean error on invalid UTF-8

The `aside.tokenizeBody` function requires valid UTF-8. Threat categories exercised:

- **Arbitrary valid UTF-8**: a purpose-built `fillValidUtf8` generator emits ASCII, 2-byte (U+00A0–U+07FF range, conservative), and 3-byte sequences (conservative E2-prefix), verifying no panic on any valid Unicode content.
- **Structured component templates**: nine templates including nested `&lt;Aside>`, unterminated components, mid-line closing tags, and unknown `kind` attributes are randomly selected and occasionally byte-corrupted (keeping ASCII range to avoid accidental UTF-8 invalidity).
- **Explicit invalid UTF-8**: a hardcoded `[0xFF, 0xFE, '<', 'A', 's', 'i', 'd', 'e', '>']` sequence asserts `error.InvalidUtf8` is returned, not a panic or a successful parse.

Category **not** exercised: semantic correctness of tokens; that valid-UTF-8 inputs produce structurally sound token output.

### Renderer seam — no-crash on bounded input

The `render.render` seam (Oliver-backed) accepts arbitrary byte slices — in production, Markdown-typed body segments after Aside tokenization. Threat categories exercised:

- **Random byte payloads**: 128 iterations of `render.render` with random byte inputs of 0–512 bytes (the renderer is byte-oriented; random bytes are allowed), each with a freshly reset arena.
- **Structured Markdown interleave**: every 3rd iteration substitutes a fixed structured Markdown string, so the no-crash property also covers real parsing paths rather than only garbage.
- **Documented error set**: `OutOfMemory`, `InputTooLarge`, `WriteFailed`, and `NoSpaceLeft` are accepted as valid outcomes alongside success — the same error set the production callers tolerate.

Category **not** exercised: HTML correctness on adversarial inputs (structured fixtures in `src/render.zig` and the Oliver contract fixtures cover that); Oliver's own parser internals; reentrancy (Oliver is stateless).

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
