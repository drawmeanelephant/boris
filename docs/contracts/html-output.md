# HTML output contract (opt-in — milestone 9 + P2/P3 extensions)

**Status:** opt-in product CLI / test-driven  
**Not** the bare-`boris` default v0.1 product surface (default remains IR under
`.boris/`; optional RAG). Default IR semantics are unchanged.

Coordinator phases (discover, parse, graph freeze, fingerprint, dirty-set) are
**sequential**. Independent HTML page render/publish may use bounded workers
when `--jobs N` is set — see [parallel-rendering.md](parallel-rendering.md).

This document is **normative for the HTML path** implemented in
`src/compile.zig` and `src/assemble.zig`. Claims below distinguish **mechanically
tested** behavior from **platform-qualified** publication notes.

---

## Scope

| In scope | Out of scope |
|----------|--------------|
| Layout load + `{{content}}` split | Bare-`boris` default mode writing `dist/` |
| Whiteboard per-page arena lifecycle | Process-RSS guarantees |
| Ordered body stream: Apex(markdown) + Aside HTML | Generic component HTML / MDX |
| Three-write layout splice | Mega-string assembly |
| Temp-file publish via Zig 0.16 Atomic API | Cross-volume atomic rename claims |
| PageDb durable metadata only | Full CommonMark (Apex stub is minimal) |
| Fixture goldens under `test/fixtures/html/` | Multi-OS CI atomicity matrix for every FS |

Modules:

- `src/compile.zig` — site loop, PageDb promote, Whiteboard, Apex render
- `src/assemble.zig` — layout split, zero-copy splice, Atomic publish
- `layouts/main.html` — default template (exactly one `{{content}}`)
- `src/apex.zig` — in-process markdown → HTML (m8)
- `src/cache.zig` / `src/dependency.zig` — fingerprints and indexes (P2)
- `src/watch.zig` — opt-in watch loop (P3.2)
- `src/target.zig` — multi-target isolation (P3.3)

CLI entry: `boris --html` / `--html-dir` / `--target` (and related flags).
Library API: `compile.compileHtmlSite` (and multi-target helpers). Related
contracts: [parallel-rendering.md](parallel-rendering.md),
[watch-mode.md](watch-mode.md),
[multi-target-isolated-output.md](multi-target-isolated-output.md).

---

## Memory model

### PageDb (long-lived)

Long-lived retain arena holds **narrowly promoted** metadata only, for example:

- `entity_id`, `source_path`, `output_path`
- `title`, `parent`, `status`, `tags`
- `body_offset` (integer, not a live buffer)
- graph role fields when populated by other paths

**Forbidden on PageDb:** any raw slice into a source buffer, parser view,
Apex HTML, buffered writer storage, or Whiteboard allocation.

Promotion duplicates strings into the retain arena **before** the source buffer
is freed (or before Whiteboard `free_all`).

### Whiteboard (document-local)

For each page:

1. Document-local `std.heap.ArenaAllocator` (“Whiteboard”).
2. Read source, parse frontmatter, tokenize body segments (markdown + Aside),
   render through Apex / `aside.renderHtml` — all transient bytes live on the
   Whiteboard.
3. Assemble/publish while slices remain valid.
4. `arena.reset(.free_all)` after every page on **success and error** paths.

### Reset ordering (hard invariant)

Reset only after **all** of:

1. Apex has returned;
2. all buffered writes are flushed;
3. temporary output has been closed/finalized;
4. publication attempt has finished (success or failure cleanup);
5. no caller-owned object retains a Whiteboard slice.

`assemble.writePage` returns only after flush + `Atomic.replace` (or failure
cleanup). `compile` runs `free_all` in a per-page `defer` **after** that return.

### What is tested vs not claimed

| Tested | Not claimed |
|--------|-------------|
| Whiteboard `queryCapacity() == 0` after `free_all` in unit/harness loops | Process RSS stays flat under all OS allocators |
| PageDb strings remain valid after each page `free_all` | No fragmentation outside the arena (GPA, libc) |
| Hold-until-flush sink: invalidate-before-flush fails; flush-then-reset succeeds | Kernel page-cache alone proves flush ordering |

---

## Layout

1. Template (e.g. `layouts/main.html`) contains **exactly one** literal
   `{{content}}` marker.
2. Load layout once at startup into **long-lived** ownership.
3. Split into immutable `prefix` / `suffix` slices referencing the long-lived
   layout buffer (`assemble.Layout`).
4. Missing marker → hard error **before** content compilation.
5. Duplicate marker → hard error **before** content compilation.
6. Final assembly writes, in three sequential writes only:
   - prefix
   - page HTML
   - suffix
7. **No** `prefix ++ html ++ suffix` (or equivalent full-page mega-string) in
   the product assembly path.

---

## Publication

### API used (Zig 0.16)

1. `Io.Dir.createFileAtomic(io, output_path, .{ .replace = true, .make_path = true })`
   — unique temp basename (hex `u64`) in the **destination directory**.
2. Stack-buffered file writer (`write_buffer_size` = 64 KiB): three `writeAll`s
   then `flush`.
3. `Io.File.Atomic.replace(io)` — same-directory rename into the final path
   (Zig std: `Dir.rename` of temp → dest).
4. `Atomic.deinit(io)` always: on failure deletes **only** this operation’s temp;
   after successful replace, temp is already consumed.

### Output path derivation

Final relative paths come from centralized
`identity.safeOutputRelativePath` / discovery PageDb `output_path`
(e.g. `guides/intro.html`). No ad-hoc path joining that can escape the output
root.

### Guarantees claimed (host-tested)

On the OS/filesystem where `zig build test` runs:

- Successful publish leaves the final file with full prefix|html|suffix bytes.
- Failed write/flush/publish deletes only the current temp; **prior final file
  is preserved** (fault-injection tests).
- No leftover hex temp names after success or injected publish failure.
- Flush completes before Whiteboard reset in the compile loop.

### Deliberately not claimed

- Universal cross-platform atomic replacement without multi-OS CI.
- Cross-device / cross-volume atomic rename.
- Windows: Zig std documents a brief window where concurrent openers of the
  destination may see `error.AccessDenied` during replace.
- IR JSON publication atomicity (separate staging path under `.boris/`).

---

## Testing matrix (release-relevant)

| Case | Location |
|------|----------|
| Layout missing marker | `assemble` + `compile` tests; `test/fixtures/layouts/` |
| Layout duplicate marker | same |
| Output equals prefix + HTML + suffix | `compile` + `assemble` |
| Premature invalidation before flush fails | `assemble.HoldUntilFlush` |
| Correct flush-then-reset succeeds | `assemble` + `compile` |
| Render failure: free_all + no final publish | `compile` |
| Write failure: prior final intact + temp cleaned | `assemble` + `compile` |
| Success publish then Whiteboard reset | `compile` |
| PageDb metadata survives each free_all | `compile` |
| Many small + one large (allocator observation) | `compile.observeWhiteboardLifecycle` |
| Fixture goldens | `test/fixtures/html/` |

Run: `zig build test` (includes assemble + compile modules).

---

## CLI contract

**Unchanged default:** `boris` without experimental flags still emits IR or RAG
only. HTML `dist/` is **not** a default product mode in m9.

Future CLI extension requires an explicit flag/docs change and must keep IR
schemaVersion stable unless IR itself changes.

---

## Related

- [`apex-abi.md`](apex-abi.md) — Apex C ABI + Whiteboard allocator rules
- [`identity-and-paths.md`](identity-and-paths.md) — safe output paths
- Narrative seeds: `docs/rag/system/05-memory-whiteboard.md`,
  `07-zero-copy-assembly.md` (descriptive; this file wins on conflict)
