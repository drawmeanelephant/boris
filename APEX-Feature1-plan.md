# Feature 1 — Real ApexMarkdown engine (Unified mode)

**Status:** revised 2026-07-14 — **corrects a wrong engine target**  
**Priority:** highest authoring-quality work after P2/P3  
**Product intent:** Keep **Apex** (the real one). Do **not** “yeet Apex” for plain cmark-gfm.

| | Wrong plan (previous) | **Correct plan (this)** |
|--|----------------------|-------------------------|
| Engine | Replace stub with **cmark-gfm alone** | Link real **[ApexMarkdown/apex](https://github.com/ApexMarkdown/apex)** |
| Mode | Hand-picked GFM extensions | **`APEX_MODE_UNIFIED`** (default — all features) |
| Identity | Fake “Apex” stub brand | Real Apex, MIT, C API |

**Canonical Boris host ABI (lifetime / Whiteboard):**  
[`docs/contracts/apex-abi.md`](docs/contracts/apex-abi.md)

**Upstream product docs:**  
[Modes wiki](https://github.com/ApexMarkdown/apex/wiki/Modes) · [C API wiki](https://github.com/ApexMarkdown/apex/wiki/C-API) · [repo](https://github.com/ApexMarkdown/apex)

---

## 1. North star

Boris’s HTML path should render Markdown with **real Apex** in **Unified mode**
(all features enabled — tables, footnotes, definition lists, math, callouts,
IAL, fenced divs, smart typography, task lists, strikethrough, etc. — see
Modes wiki).

```text
Boris body segment (Markdown bytes)
        │
        ▼
src/apex.zig  (Zig host: Whiteboard / status / no apex_free on arena)
        │
        ▼
vendor/boris-apex/apex.h   ← Boris host C ABI (KEEP: apex_render, ApexAllocator)
vendor/boris-apex/apex.c   ← thin ADAPTER only
        │
        ▼
vendor/apex-markdown/      ← real ApexMarkdown/apex (pinned release)
  apex_options_default() / APEX_MODE_UNIFIED
  apex_markdown_to_html(...)
  apex_free_string(...)
        │
        ▼  (copy into Whiteboard if custom allocator)
HTML fragment for layout splice
```

**Aside stays Zig.** Constrained `<Aside>` is still tokenized by Boris and
rendered with `aside.renderHtml`. Apex’s own callouts (`> [!NOTE]`, etc.) are
a **second** admonition syntax authors may use; do not break Aside for them.

IR / RAG still do not call Apex. Bare CLI remains IR-first (Feature 2 out of scope).

---

## 2. Critical naming fact (do not mess this up)

There are **two different “apex.h” worlds**:

| Header | Role |
|--------|------|
| **Boris host** `vendor/boris-apex/apex.h` (today: `vendor/apex/apex.h`) | Integration contract Boris wrote: `apex_render`, `ApexAllocator`, `APEX_OK/ERR_*`, Whiteboard rules |
| **Upstream** `include/apex/apex.h` in ApexMarkdown/apex | Real library: `apex_options`, `apex_mode_t`, `apex_markdown_to_html`, `apex_free_string` |

The current `vendor/apex/apex.c` is a **minimal stub**, not ApexMarkdown.

**Integration rule:** keep the **Boris host ABI** for Zig/`apex-abi.md` stability.
Implement host `apex_render` as an **adapter** that calls real Apex C API.
Never replace Boris host ABI with “only cmark-gfm.”  
Never expose raw upstream headers to Zig if that forces rewriting every
lifetime guarantee — adapter layer owns the bridge.

**Suggested tree after the rename (recommended):**

```text
vendor/boris-apex/          # Boris host ABI + adapter (moved from vendor/apex/)
  apex.h                    # UNCHANGED public host API
  apex.c                    # adapter → real Apex
  apex_hostile.c
  apex_sanitize_smoke.c
vendor/apex-markdown/       # pin of github.com/ApexMarkdown/apex @ vX.Y.Z
  include/apex/...
  src/...
  vendor/cmark-gfm/         # Apex’s submodule (Apex already depends on it)
  vendor/libyaml/           # optional; document if disabled
  VENDOR.md
```

If renaming paths mid-flight is too noisy, keep paths under `vendor/apex/` for
the **host** and put the real engine in `vendor/apex-markdown/` only — but
**never** overwrite Boris `apex.h` with upstream’s.

---

## 3. Default product: Unified mode

From [Modes](https://github.com/ApexMarkdown/apex/wiki/Modes):

| Mode | Use |
|------|-----|
| **`unified`** | **Boris default.** All features. |
| `gfm` | GitHub-strict subset |
| `mmd` / `multimarkdown` | MultiMarkdown-ish |
| `kramdown` | Kramdown-ish |
| `commonmark` | Pure CommonMark (no tables, etc.) |
| `quarto` | Pandoc/Quarto-oriented |

**v1 ship configuration (hardcoded in adapter unless mode config lands):**

```c
apex_options opts = apex_options_default(); /* Unified family defaults */
/* or: apex_options_for_mode(APEX_MODE_UNIFIED); */

opts.output_format = APEX_OUTPUT_HTML;
opts.standalone = false;   /* fragment only — Boris layouts wrap pages */
opts.pretty = false;       /* stable, compact HTML for goldens/cache */
opts.unsafe = true;        /* trusted author content; raw HTML allowed */
opts.validate_utf8 = true;

/* SSG safety / avoid double systems (see §5) */
opts.enable_file_includes = false;  /* Boris has its own include graph */
opts.enable_plugins = false;
opts.code_highlighter = NULL;       /* no external highlighter subprocesses */
opts.ast_filter_count = 0;
```

Tune further only with documented reasons (e.g. wiki links on/off).

---

## 4. Should modes be configurable?

**Short answer:** Unified-only for Feature 1. Optional modes later if needed —
not day one.

| Approach | Verdict |
|----------|---------|
| **Hardcode Unified** | **Do this first.** Matches “strong Apex.” One golden surface. |
| **Site-level mode** (`--apex-mode gfm`) | Good **follow-up** if authors need GFM-strict or CommonMark-strict sites. |
| **Per-page mode in frontmatter** | Usually a **bad** idea: same project renders inconsistently; hard to reason about nav/cache. |
| **Expose every `apex_options` flag on CLI** | **No** for v1. Explosion of surface; Apex already has metadata toggles upstream. |

If you add modes later:

1. Default remains `unified`.
2. Allow only an **allowlist**: `unified | gfm | commonmark | mmd | kramdown | quarto`.
3. Prefer **build/site config** or a single CLI flag, not per-file chaos.
4. Changing mode must invalidate HTML cache fingerprints (include mode string in
   cache key).

---

## 5. Adapter design (Boris host → real Apex)

### 5.1 `apex_render` (host) algorithm

1. Zero `*out_html` / `*out_len` on entry.
2. Validate args → `APEX_ERR_ARGS`.
3. Build `apex_options` (§3).
4. Call:

   ```c
   char *html = apex_markdown_to_html(md, md_len, &opts);
   ```

5. If `html == NULL` → map to `APEX_ERR_OOM` or `RenderFailed` policy
   (prefer OOM only when truly alloc; otherwise non-zero that Zig maps to
   `RenderFailed` — document in adapter).
6. **Ownership transfer into Boris allocator:**
   - Measure `len = strlen(html)` (Apex returns C string; length from strlen is
     OK for its contract) **or** prefer a length if API grows one.
   - If custom `ApexAllocator`: `out = alloc(len)` (or `len` without forcing
     extra NUL if host doesn’t need it); `memcpy`; **`apex_free_string(html)`**;
     set `*out_html` / `*out_len` to arena buffer.
   - If `allocator == NULL`: either return Apex’s buffer and document that
     `apex_free` must free via `apex_free_string` **or** `malloc`+copy+free
     Apex string so host `apex_free` stays libc-free. Prefer **one clear path**
     tested by sanitize smoke.
7. Retain **no** Apex pointers after return.
8. Synchronous only; no plugins that spawn work after return.

**Why copy into the arena?**  
Upstream Apex allocates with its own heap (`apex_free_string`). Boris Whiteboard
requires arena-owned HTML and **forbids** `apex_free` on arena memory. Copy +
free is the correct bridge and keeps `apex-abi.md` honest without forcing a
custom-allocator patch into upstream Apex.

### 5.2 Version string

`apex_version()` (host) → e.g. `boris-apex/apex-markdown-1.1.11+unified`.

### 5.3 Hostile double

Unchanged: `apex_hostile.c` still replaces the **host** engine for Zig wrapper
tests. Does not link real Apex.

---

## 6. Vendoring & build (hardest practical problem)

Real Apex is a **CMake + submodules** project:

- Core C under `src/`
- Depends on **cmark-gfm** (submodule) — *as Apex’s engine substrate*, not as
  Boris’s public renderer
- Optional **libyaml** for rich YAML metadata
- License: **MIT**

### 6.1 Pin

Pin a **release tag** (e.g. `v1.1.11` or whatever is current when implementing).
Record in `vendor/apex-markdown/VENDOR.md`: URL, tag, commit SHA, date, license.

```bash
# conceptual — implement carefully, no network at *consumer* build time
git clone --branch v1.1.11 --depth 1 https://github.com/ApexMarkdown/apex.git
# init required submodules at that pin
```

Prefer a **vendored snapshot** committed (or subtree) so `zig build` stays
offline.

### 6.2 Link strategy (pick one; document choice)

| Strategy | Pros | Cons |
|----------|------|------|
| **A. CMake static lib, Zig links `.a`** | Matches upstream build | Requires cmake on builder machines; AGENTS allows C under vendor, but cmake is a **build tool** — document as host dependency for compile only, not runtime |
| **B. Compile Apex + cmark-gfm sources via `build.zig`** | Pure zig cc | Fragile file lists; config headers; higher maintenance |
| **C. System-installed libapex** | Easy locally | Breaks reproducible offline builds — **reject for product** |

**Recommendation:** Strategy **A** for correctness of first land (build static
`libapex` + deps once, link from `build.zig`), with a clear error if cmake
missing. Strategy B as a later hardening if you want zero cmake.

AGENTS.md forbids replacing Zig’s build system as **primary** — invoking cmake
as a **sub-step to produce a static library** is acceptable if `zig build`
remains the user entrypoint. Do **not** make `make && cmake` the documented
primary UX.

### 6.3 What to disable at the Boris boundary

| Upstream feature | Boris default | Why |
|------------------|---------------|-----|
| File includes | **off** | Boris already has graph-aware includes |
| Plugins / filters | **off** | Subprocess / untrusted code risk |
| External code highlighters | **off** | Subprocess; AGENTS forbids MD CLI spawn |
| Standalone HTML | **off** | Layout splice owns chrome |
| Indices / bibliography | Unified defaults OK | Can trim later if noisy |
| Wiki links | off unless enabled | Modes wiki: off by default even in unified |

---

## 7. Test plan

### 7.1 Gates

```bash
zig build
zig build test
zig build test-apex-hostile
zig build test-apex-sanitize   # PASS or documented SKIP
./scripts/release-gate.sh
```

### 7.2 Fidelity (Unified-oriented)

Prefer structural asserts + a few goldens — not full Apex’s 1800 suite.

| ID | Construct (Unified) | Assert |
|----|---------------------|--------|
| U1 | GFM table | `<table` |
| U2 | Nested lists | nested `<ul>`/`<ol>` |
| U3 | Blockquote | `<blockquote` |
| U4 | Fenced code | escaped content in `<pre><code` |
| U5 | Strikethrough `~~x~~` | del/s |
| U6 | Task list | checkbox markup |
| U7 | Footnote | footnote ref/backref structure |
| U8 | Definition list | `<dl` / `<dt` / `<dd` |
| U9 | Math `$x$` / `$$y$$` | math delimiters/spans as Apex emits |
| U10 | Callout `> [!NOTE]` | callout markup |
| U11 | IAL / heading attributes | id/class if easy |
| U12 | Fenced div | `<div` with class from IAL |
| U13 | Empty + non-NUL-terminated input | no crash; bounded parse |
| U14 | OOM / alloc path | custom allocator still safe |
| U15 | Aside order | Zig Aside stream unchanged |
| U16 | Dual-run HTML | byte-identical on one host |
| U17 | No file include side effects | body with `{{foo}}` / include syntax does **not** pull disk when includes disabled |

Update stub-era HTML goldens with reasons.

---

## 8. Implementation phases

### Phase A — Baseline + correct pin

1. Read this plan + `apex-abi.md` + `src/apex.zig` + `build.zig` `linkApex`.
2. Baseline commands.
3. Vendor ApexMarkdown/apex at pin + submodules + `VENDOR.md` + LICENSE.
4. **Do not** merge cmark-gfm-as-Boris-renderer plans.

### Phase B — Build link

1. Produce static library (cmake sub-step or zig-cc list).
2. Compile host adapter that still may stub until Phase C.
3. Hostile path unchanged.

### Phase C — Adapter

1. Implement host `apex_render` → `apex_markdown_to_html` + copy + free.
2. Unified options from §3.
3. Version string.
4. Unit tests U13–U14 + basic heading.

### Phase D — Fidelity + goldens

1. U1–U17.
2. Golden updates.
3. Aside regression.

### Phase E — Docs

1. `apex-abi.md`: stub → **ApexMarkdown adapter**; host ABI rules unchanged.
2. STATUS Feature 1 **Done** only when gates green.
3. Narrative seeds: real Apex Unified, not cmark-gfm product story.
4. CHANGELOG.
5. Mark this plan Implemented + commit.

**Optional Phase F (later):** `--apex-mode` allowlist + cache key.

---

## 9. Non-negotiables

- Real engine = **ApexMarkdown/apex**, not “cmark-gfm replaces Apex.”
- Default mode = **Unified**.
- Boris host ABI / Whiteboard / no `apex_free` on arena HTML preserved.
- In-process only; no `apex` CLI subprocess for page render.
- No Feature 2 (HTML default CLI).
- No IR `schemaVersion` bump.
- Aside path remains Zig.
- If adapter cannot satisfy host lifetime rules → **stop**, report options
  (do not weaken contract).

---

## 10. Definition of done

- [ ] ApexMarkdown/apex vendored & pinned; licenses present
- [ ] Host `apex_render` uses real Apex Unified (fragment HTML)
- [ ] File includes / plugins / external highlighters off at Boris boundary
- [ ] Whiteboard path: copy-in + `apex_free_string`; no arena free via libc
- [ ] Hostile tests still green
- [ ] Fidelity tests for Unified constructs green
- [ ] `zig build test` + release-gate green
- [ ] Docs claim **ApexMarkdown Unified**, not cmark-gfm-as-product
- [ ] No Feature 2; no accidental mode sprawl

---

## 11. Prompt seed (implementing agent)

```text
Implement Feature 1 from APEX-Feature1-plan.md ONLY.

Engine: real https://github.com/ApexMarkdown/apex (pinned release), NOT
cmark-gfm as Boris’s public renderer. cmark-gfm may exist only as Apex’s
upstream dependency.

Default: APEX_MODE_UNIFIED via apex_options_default / for_mode, HTML fragment,
standalone=false, unsafe=true, file includes OFF, plugins OFF, no external
code highlighters.

Keep Boris host ABI (apex_render / ApexAllocator / apex-abi.md). Adapter:
apex_markdown_to_html → copy into host allocator → apex_free_string.

Do not start Feature 2. Do not flip CLI default to HTML. Do not rewrite Aside.
If lifetime bridge fails, STOP and report.

Gates: zig build, zig build test, test-apex-hostile, test-apex-sanitize
(or SKIP), ./scripts/release-gate.sh.
```

---

## 12. Review checklist

1. Is the engine **ApexMarkdown**, not a cmark-gfm-only product path?
2. Is default mode **Unified**?
3. Are host `apex.h` lifetime rules intact?
4. Copy + `apex_free_string` (no free of arena via Apex free)?
5. Includes/plugins/highlighters off?
6. Hostile still isolated?
7. Docs no longer say “replace Apex with cmark”?
8. Mode configurability deferred unless explicitly scoped?

---

## 13. Apology / history note

Earlier Feature 1 drafts aimed at **cmark-gfm under a fake Apex stub ABI**. That
was the wrong product goal for this repo: Boris’s name and architecture always
meant **Apex the processor**, with a thin host integration layer. This plan
restores that intent: **strong Apex = real ApexMarkdown in Unified mode.**
