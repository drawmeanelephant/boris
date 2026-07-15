# HTML output contract (default CLI — milestone 9 + P2/P3 + Feature 2)

**Status:** default product CLI surface / test-driven  
Bare `boris` builds an HTML site under `dist/`. JSON IR remains available via
`--out` / `--no-rag`. Optional RAG is unchanged (`--rag` / `--rag-dir`).

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
| Layout load + `{{content}}` split | Process-RSS guarantees |
| Whiteboard per-page arena lifecycle | Generic component HTML / MDX |
| Ordered body stream: Apex(markdown) + Aside HTML | Mega-string assembly |
| Three-write layout splice | Cross-volume atomic rename claims |
| Temp-file publish via Zig 0.16 Atomic API | Full YAML frontmatter / MDX |
| PageDb durable metadata only | Multi-OS CI atomicity matrix for every FS |
| Fixture goldens under `test/fixtures/html/` | |
| Bare `boris` default → `dist/` (Feature 2) | |

Modules:

- `src/compile.zig` — site loop, PageDb promote, Whiteboard, Apex render
- `src/assemble.zig` — layout split, zero-copy splice, Atomic publish
- `layouts/main.html` — default template (exactly one `{{content}}`)
- `src/apex.zig` — in-process markdown → HTML (m8)
- `src/cache.zig` / `src/dependency.zig` — fingerprints and indexes (P2)
- `src/watch.zig` — opt-in watch loop (P3.2)
- `src/target.zig` — multi-target isolation (P3.3)

CLI entry: bare `boris` (default), or `--html` / `--html-dir` / `--target`
(and related flags). Library API: `compile.compileHtmlSite` (and multi-target
helpers). Related contracts: [parallel-rendering.md](parallel-rendering.md),
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

1. Template (e.g. `layouts/main.html`) is scanned once for **known** markers.
   Load layout once at startup into **long-lived** ownership.
2. **Required marker:** exactly one `{{content}}` (page body: Apex + Aside HTML).
3. **Optional markers** (each at most once):

   | Marker | Value |
   |--------|--------|
   | `{{nav}}` | Full site forest (Trunks id-ascending, nested Satellites id-ascending) |
   | `{{breadcrumb}}` | Parent chain root → current page (inclusive) |
   | `{{title}}` | Page title, or entity id when title is absent (HTML-escaped text) |
   | `{{toc}}` | In-page outline from **this page’s** body headings (h1–h3 with `id`) |

4. Missing `{{content}}` → hard error **before** content compilation.
5. Duplicate of any known marker → hard error **before** content compilation.
6. Unknown `{{…}}` token → hard error **before** content compilation (fail loud).
7. Split into an ordered list of **static** slices and **slot** placeholders
   (`assemble.Layout`), all views into the long-lived layout buffer.
8. Final assembly streams sequential writes only: static segments and per-page
   slot fragments (content, and nav/breadcrumb/title/toc when those slots exist).
   **No** full-page mega-string concatenation in the product assembly path.

### Graph gate (HTML path)

Before any page render, the HTML path:

1. Maps promoted PageDb metadata to graph nodes (views into retain-owned strings).
2. Runs the same `graph.validate` rules as IR/RAG (`EPARENT*`, duplicates, cycles).
3. On any error diagnostic: **do not** publish HTML pages; exit **1** (content).
4. On success: freeze the graph, `buildNav`, and use the frozen snapshot for
   `{{nav}}` / `{{breadcrumb}}` (and fingerprint material when `{{nav}}` is present).

### Site nav HTML (normative shape)

When `{{nav}}` is present, emit a deterministic forest (no hash-map order):

```html
<nav class="site-nav" aria-label="Site">
  <ul>
    <li class="site-nav__trunk[ is-current]"><a href="REL">TITLE</a>
      <ul>
        <li class="site-nav__satellite[ is-current]"><a href="REL">TITLE</a></li>
      </ul>
    </li>
  </ul>
</nav>
```

- `REL` is a **site-relative path from the current page’s output path** to the
  target (e.g. from `guides/x.html` to `index.html` → `../index.html`). Never
  a leading-`/` site-absolute path.
- Titles (and link text) are HTML-escaped (`& < > "`).
- `is-current` marks the `li` for the page being rendered; the current link may
  use `aria-current="page"`.

When `{{breadcrumb}}` is present:

```html
<nav class="breadcrumb" aria-label="Breadcrumb">
  <ol>
    <li><a href="REL">TITLE</a></li>
    <li aria-current="page">TITLE</li>
  </ol>
</nav>
```

Last crumb is the current page (unlinked text). Earlier crumbs are links.

### Incremental fingerprints and `{{nav}}`

When the layout contains `{{nav}}`, each page fingerprint includes a **site nav
material** digest derived from the frozen ordered list of
`(id, title, parent, role)` for every page. A title or parent change on any
page dirties every page that uses that layout (full forest is global chrome).
Layouts without `{{nav}}` keep the prior page-local fingerprint inputs
(source, includes, layout bytes, entity id, target identity).

### Incremental cache freshness (output digest)

On `--incremental`, a page is **reused** only when all of the following hold:

1. Prior `dist/.boris-cache/manifest.json` parses and its `format_version`
   equals the fingerprint discriminator (`boris-cache-v1-multitarget`).
2. A manifest entry matches the page’s `entity_id`, `output_path`, and current
   **input** fingerprint (source / includes / layout / target / nav material).
3. The on-disk HTML file exists and is non-empty.
4. The file’s **SHA-256** (lowercase hex) equals the entry’s `output_digest`.

`output_size` is recorded as a **cheap prefilter** only. Same-length
corruption of published HTML must still fail the digest check and force a
re-render. Missing or empty `output_digest` (older manifests under the same
format version) forces re-render — deliberate forward-compatible fail-closed
behavior without bumping `format_version` or reshaping input fingerprints.

Manifest entry shape (deterministic field order; entries follow PageDb order):

```json
{
  "entity_id": "guides/intro",
  "fingerprint": "<64 hex chars>",
  "output_path": "guides/intro.html",
  "output_size": 1234,
  "output_digest": "<64 hex chars>"
}
```

Two incremental runs with identical inputs and intact outputs must produce
byte-identical manifests. Truncation, replacement, or same-size bit flips of
published HTML must re-render the affected page while leaving truly unchanged
siblings cached.

### Includes and wiki-links (pre-Apex)

Before Aside tokenize and Apex, the HTML path:

1. Expands `{{include path}}` (Boris-mediated; Apex FS includes stay off).
2. Rewrites `[[entity-id]]` wiki-links to relative Markdown links.

Included headings participate in `{{toc}}` (TOC is built from rendered body
HTML after expansion). Normative syntax and errors:
[includes-and-wiki-links.md](includes-and-wiki-links.md).

`{{toc}}` is **page-local** (derived from that page’s body). It does **not**
add global fingerprint material; source/layout inputs already cover heading
edits on the same page.

### In-page `{{toc}}` (normative shape)

When `{{toc}}` is present, after body render (Apex + Aside stream):

1. Scan the **rendered body HTML** for `h1`–`h3` elements that have an `id`
   attribute (document order). Do **not** re-slug Markdown independently —
   anchors must match Apex-emitted ids.
2. Levels `h4`–`h6` are omitted from the outline (still render in the body).
3. Headings without `id` are omitted.
4. When zero qualifying headings exist, emit an **empty** fragment (no empty
   chrome wrapper).
5. Otherwise emit:

```html
<nav class="page-toc" aria-label="On this page">
  <ul>
    <li class="page-toc__lN"><a href="#ID">TEXT</a></li>
  </ul>
</nav>
```

- `N` is the heading level (`1`–`3`).
- `ID` is HTML-escaped for the attribute.
- `TEXT` is the heading’s inner text with tags stripped; HTML entities already
  present in the body (e.g. `&amp;`) are **not** double-escaped.
- Nested `<ul>` structure is **not** required in v0; level classes allow CSS
  indent. Flat list preserves document order.

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
- Cross-device / cross-volume **atomic** rename (stage commit falls back to
  copy+delete on `error.CrossDevice`; completeness only, not atomicity).
- Windows: Zig std documents a brief window where concurrent openers of the
  destination may see `error.AccessDenied` during replace.
- IR JSON publication atomicity (separate staging path under `.boris/`).

---

## Testing matrix (release-relevant)

| Case | Location |
|------|----------|
| Layout missing marker | `assemble` + `compile` tests; `test/fixtures/layouts/` |
| Layout duplicate marker | same |
| Unknown / multi-slot layout markers | `assemble` multi-slot tests |
| Graph gate on HTML (bad parent) | `compile` Feature 6 tests |
| Site nav + breadcrumb + relative href | `html_nav` + `compile` Feature 6 tests |
| In-page `{{toc}}` from body heading ids | `html_toc` + `compile` Feature 6 follow-on tests |
| Output equals prefix + HTML + suffix | `compile` + `assemble` (content-only layouts) |
| Premature invalidation before flush fails | `assemble.HoldUntilFlush` |
| Correct flush-then-reset succeeds | `assemble` + `compile` |
| Render failure: free_all + no final publish | `compile` |
| Write failure: prior final intact + temp cleaned | `assemble` + `compile` |
| Success publish then Whiteboard reset | `compile` |
| PageDb metadata survives each free_all | `compile` |
| Many small + one large (allocator observation) | `compile.observeWhiteboardLifecycle` |
| Fixture goldens | `test/fixtures/html/` |
| Incremental same-size corruption / truncation / reuse / full=inc / manifest determinism | `compile` P4 cache freshness test |

Run: `zig build test` (includes assemble + compile modules).

---

## CLI contract

**Default (Feature 2):** bare `boris` (and HTML-only flags such as `--jobs`,
`--watch`, `--incremental`) builds an HTML site under `dist/` (or
`--html-dir` / `--target` roots).

**IR opt-in:** `--out <DIR>` or `--no-rag` selects JSON IR under `--out`
(default `.boris`). Explicit `--html` / `--html-dir` / `--target` with `--out`
or RAG flags is a usage error (exit 2).

IR `schemaVersion` is unchanged by the default flip unless JSON IR shape
changes.

---

## Related

- [`apex-abi.md`](apex-abi.md) — Apex C ABI + Whiteboard allocator rules
- [`identity-and-paths.md`](identity-and-paths.md) — safe output paths
- Narrative seeds: `docs/rag/system/05-memory-whiteboard.md`,
  `07-zero-copy-assembly.md` (descriptive; this file wins on conflict)
