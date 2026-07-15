# Boris — Code Review (v0.1.1)

**Reviewer:** Claude (for Beau → Timothy)
**Date:** 2026-07-15
**Subject:** Boris — Zig static-site generator with vendored "Apex" C markdown engine
**Scope:** Open-ended correctness / design / security review of the full source tree
(~14,500 lines Zig across 24 files + 318-line C engine).

---

## How this was reviewed (read this first)

Timothy handed over **three RAG knowledge-dump files**, not a git repo — the project's own
source flattened into markdown code-fences for LLM upload. I reconstructed the actual source
tree from them (135 files, verified intact) so it could be read as code.

**Caveat:** this is a *static* review. Zig is not installed on this machine, so **nothing was
compiled, built, or run.** Findings come from tracing the code and cross-checking it against the
project's own contract docs and test fixtures. Every headline finding below was verified by hand
against the actual lines, not taken on a tool's word — but a live `zig build test` is the
obvious next gate before acting on anything, and would likely surface more.

**Bottom line:** this is a genuinely well-built project. The highest-risk surface — a C engine
parsing untrusted markdown — is **clean** on memory safety. The real issues are all in the Zig
layer: one contract-violating correctness gap, a couple of robustness/reliability bugs, and a
chunk of misleading dead code. None are catastrophic; all are fixable.

---

## Findings (prioritized)

### 🔴 HIGH-1 — Case-only duplicate IDs are never detected → silent output collision
**`src/graph.zig:84` (`diagnoseDuplicateIds`)**

The live duplicate-id check compares IDs with byte-exact `std.mem.eql` only. Two pages whose
entity IDs differ only in case — `guides/intro` and `GUIDES/INTRO` — both pass validation, both
promote, and the build succeeds with **zero diagnostics**. On a case-insensitive filesystem
(macOS APFS default, Windows NTFS default) their output paths `guides/intro.html` and
`GUIDES/INTRO.html` collide — one silently overwrites the other.

The project *knows* this should be caught: there's a dedicated fixture
`docs/contracts/fixtures/case-id-collision/` whose README requires `diagnoseDuplicateIds` to emit
`EINVALIDPATH`. But the fixture is **unwired** — `grep` shows zero references to it anywhere in
`src/`, unlike every sibling fixture (cycles, duplicate-ids, missing-parent…) which are all
wired into `pipeline.zig`. The case-fold logic (`pathsDifferOnlyInCase`) exists — but only in
dead code (see MED-3).

**Fix:** in `diagnoseDuplicateIds`, add a second pass (sort by lower-cased ID, or a case-folding
hashmap) reusing `identity.pathsDifferOnlyInCase`, emitting `EINVALIDPATH` per the fixture. Then
wire the `case-id-collision` fixture into the pipeline test so it can't regress.

---

### 🟠 HIGH-2 — RAG export destroys the previous corpus if the new build fails
**`src/rag.zig:1058` (`publishCorpus`)**

Publish does `deleteTree(out_dir)` **before** attempting the rename/copy of the new corpus. If the
directory rename fails (cross-volume, permissions) *and* the file-by-file fallback copy then fails
partway (disk full, one bad file, interrupted process), the function returns an error with the old
`rag/` tree **already gone and no rollback**. The doc comment admits a transient "missing tree"
window, but the actual failure mode is *permanent loss* of a working corpus, not just a visibility
blip. Note `pipeline.zig`'s IR publish does this correctly — per-file rename into the existing dir,
no pre-delete.

Severity is High for reliability but the lost artifact is *regenerable* (re-run the export), so
it's data-loss-of-output, not of source.

**Fix:** copy/rename the new corpus into place **first**, and only `deleteTree` the old one after
the replacement is fully confirmed — i.e. build-beside-then-swap, never delete-then-build.

---

### 🟠 MEDIUM-1 — Malformed aside tag causes quadratic-time build hang
**`src/aside.zig:396` (closing-`>` scan)**

The scan for a tag's closing `>` toggles an `in_quote` flag on every `"`. A single **unmatched**
quote inside an open tag leaves `in_quote = true` for the rest of the document, which suppresses
the `<`-based early-exit — so the scan runs to end-of-file instead of stopping at the next tag.
With many malformed `<Aside k="…` occurrences in one file, each independently rescans the whole
remainder: O(tags × N) ≈ **O(N²)**. A ~1 MB file (within the 1 MiB source limit) can make the
compiler hang.

For a static-site generator building the *author's own* trusted content this is a "malformed
input hangs the build mysteriously" DX bug rather than an attack. **It rises to HIGH if Boris ever
builds untrusted content** (e.g. external-PR previews in CI).

**Fix:** when a closing `>` isn't found before EOF, resume the outer scan from the failure point
rather than re-entering; or reset/bound `in_quote` so an unterminated quote can't disable the
`<` early-exit for the rest of the file.

---

### 🟡 MEDIUM-2 — Unbounded recursion in cycle-detection DFS
**`src/graph.zig:258` (`Dfs.visit`)**

`visit` recurses once per parent-chain hop with real work *after* the recursive call, so it is
not tail-call-eliminable. A very long (even non-cyclic) parent chain — tens of thousands of
satellites each pointing at the previous — walks the entire chain recursively and can blow the
thread stack, crashing the compiler instead of emitting diagnostics. `buildBreadcrumb` in the same
file already does this iteratively with a hop guard — the DFS should follow that pattern.

**Fix:** convert `Dfs.visit` to an explicit loop over the already-allocated `stack`/`colors` state.

---

### 🟡 MEDIUM-3 — `src/discover.zig` (596 lines) is dead code that contradicts the live scanner
**`src/discover.zig` (entire file)**

Not imported by any production module and not wired into `build.zig` at all. It's a divergent
second copy of discovery with *different* semantics from the shipped `scanner.zig` (continues past
symlinks/case-collisions vs. scanner's hard-abort), and — ironically — it contains the very
case-collision detection (`diagnoseEntityCaseCollisions`) that HIGH-1 is missing from the live
path. A maintainer editing "the scanner" per the contract will reasonably mistake this for live
or safely-deletable reference code; it's neither. Classic rot: untested-by-CI, silently disagrees
with shipped behavior.

**Fix (pick one, don't leave both):** either port `diagnoseEntityCaseCollisions` into the live
graph path (this *is* the HIGH-1 fix) and delete `discover.zig`, or wire it in to replace
`scanner.zig`. Right now it's the worst of both worlds.

---

### 🟡 MEDIUM-4 — Documented `boris_version` is stale (`0.0.1` vs actual `0.1.1`)
**`docs/contracts/rag-export.md:6,101`**

The contract's normative example says `catalog_meta.json` carries `"boris_version":"0.0.1"`, but
the real constant (`pipeline.zig:20`, matching `build.zig.zon`) is `0.1.1`. Every actual export
contradicts the documented value. The stale `0.0.1` also appears in `docs/AUDIT-v0.1.md`,
`docs/STATUS.md`, and `docs/rag/system/09-rag-export.md` (which ships *inside* the corpus). Since
the contract is the acceptance oracle, this is a real (if low-stakes) doc/impl divergence.

**Fix:** sweep docs to `0.1.1`, or make the example version-agnostic. Worth deciding whether these
docs should be generated at release rather than hand-maintained.

---

### 🟢 LOW-1 — Bare trailing CR at EOF wrongly closes frontmatter
**`src/parser.zig:128` (`readPhysicalLine`)**

Strips a trailing `\r` unconditionally, even when it's an isolated CR at true EOF (no following
`\n`) — contradicting the module's own documented rule that "isolated CR is not a line break."
Input `"---\ntitle: X\n---\r"` (file ends on a bare CR) has its `---\r` accepted as a valid closing
fence instead of being rejected as unclosed frontmatter.

**Fix:** only strip trailing `\r` when the line actually ended in `\n` (a real CRLF pair).

---

### 🟢 LOW-2 — O(n²) parent-index remap in `graph.freeze()`
**`src/graph.zig:374`**

After sorting nodes, `freeze` remaps every `parent_index` via `findIndexById` (linear scan) —
O(n²) total, on every build. A hashmap (the `buildIdIndex` pattern already used elsewhere in the
file) makes it O(n). Invisible at small scale, real at 10k+ pages.

---

### 🟢 LOW-3 — Diagnostic-only nits
- `src/aside.zig:634` (`exportBodyWithDirectives`): leaks the `prepared` markdown buffer in the
  `.markdown` branch (no `defer free`). Currently **unwired** (no callers), so latent — will leak
  once used with a non-arena allocator.
- `src/frontmatter.zig`: fuzz/harness-only module doesn't enforce the tag/field/size bounds the
  contract calls a "single source of truth" — off the production path, but a divergence.
- `vendor/apex/apex.c:75` and `apex_sanitize_smoke.c:18`: dead/unreachable branches in the C
  engine's buffer-reserve and a test double's fake allocator — harmless, but they obscure the
  (correct) overflow-handling logic.

---

## What's genuinely good (don't touch these)

- **The C engine is clean.** Every buffer-growth path in `apex.c` guards against `size_t`
  overflow before multiplying/adding; the old buffer is only freed after the new allocation is
  confirmed; delimiter scans are all bounds-checked; empty/huge/malformed-UTF-8/deep-nesting
  inputs were all traced without a crash path. This was the highest-risk surface and it holds up.
- **The Zig↔C ABI boundary is disciplined.** `apex.zig` pulls C types via `@cImport` (rules out
  extern-signature drift) and pins width/arity/status constants with comptime asserts. Ownership
  and status-before-reading-output rules match the contract exactly.
- **CLI is thorough.** Flag conflicts, mode selection, and exit codes 0/1/2/3 line up 1:1 with
  the documented contract, each with an explicit test.
- **Zero-copy layout splicing (`assemble.zig`) is careful and correct** — flush-before-replace,
  flush-before-arena-reset, and temp-file cleanup on failure are all enforced and test-covered by
  a fingerprint harness that would catch a real use-after-free.
- **Path traversal is closed at parse time** — a malicious `id:`/`parent:` frontmatter override
  is rejected by `identity.validateEntityId` before it can reach the RAG/IR writers.
- **RAG output is deterministic** — stable sorts, no timestamps/absolute paths, per the contract.
- **Careful error-path memory management** in `graph.buildNav` (bounded errdefer, no double-free)
  and `page.PageDb.promote` (dupes all strings before the source buffer is freed).

---

## Recommended next steps (the "then fix" phase)

1. **Get a buildable tree + Zig 0.16** (from Timothy's real repo if it exists, or from this
   reconstruction) and run `zig build test`. Confirm the suite is green before changing anything.
2. **Fix HIGH-1 by resolving MED-3**: port the case-collision check from `discover.zig` into the
   live `graph.zig`, wire the `case-id-collision` fixture, delete `discover.zig`. One change,
   closes two findings and removes the rot.
3. **Fix HIGH-2**: reorder `publishCorpus` to swap-then-delete.
4. **Fix MED-1 / MED-2**: bound the aside scan; make the DFS iterative. Both are small, both
   prevent build hangs/crashes on pathological input.
5. **Doc sweep** for MED-4 and the LOW items as cleanup.

I can take any of these hands-on once we have a tree that builds. My suggestion: start with #2 —
it's the highest-value single change and it deletes code rather than adding it.

---

*Reconstructed source tree: `~/projects/boris/repo/` · Original dumps: `~/projects/boris/boris-{source,docs,content}.md`*
