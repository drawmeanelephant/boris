# Oliver renderer contract (pin, seam, upgrade)

**Status:** normative — Markdown → HTML rendering and the Cooklang seam  \
**Module:** [`src/render.zig`](../../src/render.zig) (Markdown → HTML) and
[`src/cooklang_seam.zig`](../../src/cooklang_seam.zig) (`.cook` parsing). Both
consume the single `oliver` pin.  \
**Upstream:** <https://github.com/drawmeanelephant/oliver>  \
**Related:** [html-output.md](html-output.md), [heading-ids.md](heading-ids.md),
[parallel-rendering.md](parallel-rendering.md),
[includes-and-wiki-links.md](includes-and-wiki-links.md)

---

## What Oliver is, and the boundary

Oliver is a freestanding Zig markup library: source bytes → normalized typed
document → deterministic HTML. It is pure Zig (no libc, no host tools, no
filesystem/clock/network access, no global state), consumed natively as a Zig
module — never a subprocess, never a shell-out to a CLI.

Boris owns everything outside the seam, exactly as before:

- filesystem discovery, frontmatter, include expansion, wiki-link rewriting,
  content-local asset rewriting, Aside tokenization
- graph semantics, layout/template assembly, publication paths, routing
- evidence/provenance, diagnostics, site-level policy

`src/render.zig` is the **only** place Boris touches Oliver's API. Production
Markdown bodies go through `render.render(md, arena)` with the same Whiteboard
arena lifetime contract the previous renderer's `Html` view had: returned bytes
are valid until `arena.reset(.free_all)`.

## Pinned revision (exact)

| Field | Value |
|-------|-------|
| Repository | <https://github.com/drawmeanelephant/oliver> |
| Branch | `main` |
| Commit | `c0b3d2b683f0cecf2181b22a800908619e56d0d7` |
| Package hash | `oliver-0.0.0-LOsZkAe_HwD1k4BLmgWJcT9AI3AopaxmZwjc2gx-23pz` |
| Zig | 0.16.0 |

The pin lives in `build.zig.zon` (`.dependencies.oliver.url` + `.hash`). Zig
verifies the content hash at fetch time, so a checkout is reproducible with no
globally installed `oliver` executable, no PATH tricks, no environment-specific
clone, and no network access at runtime (the package is fetched once at build
time and cached by Zig).

### Why this revision

Oliver upstream is CommonMark 0.31.2 (652/652 conformance) plus GFM tables.
The pinned revision is Oliver `main` as of oliver#39's merge (`c0b3d2b`): the
Markdown renderer extensions and the Cooklang stack share one revision. Boris
publishes five dialect extensions Oliver added for the renderer migration, all
off by default in Oliver and opted into by Boris (so Oliver's own conformance
corpus stays byte-exact):

| Extension | Oliver option | Boris uses for |
|-----------|---------------|----------------|
| GFM heading auto-ids | `render.heading_ids` | wiki fragments + `{{toc}}` anchors (`heading-ids.md`) |
| Heading attribute lists (`{#id .class}`) | `parse.markdown.heading_attributes` | manual ids such as `{#exit-codes}` in `reference/commands.md` |
| Footnotes (`[^label]` + definitions) | `parse.markdown.footnotes` + `render.footnotes` | footnote refs/sections in published pages |
| Definition lists (`Term` + `: def`) | `parse.markdown.definition_lists` | definition lists in published pages |
| GFM strikethrough (`~~x~~`) | `parse.markdown.strikethrough` | Textile `-deleted-` and authored `~~x~~` (`textile-compatibility.md`) |

`src/render.zig` pins these options in one place:

```zig
const markdown_options = oliver.MarkdownOptions{
    .footnotes = true,
    .definition_lists = true,
    .heading_attributes = true,
    .strikethrough = true,
};
const render_options = oliver.html.RenderOptions{
    .heading_ids = true,
    .footnotes = true,
    // .profile = .html (default) | .xhtml — per-target via `--target-profile`
};
```

The default profile is `.html` and its output is byte-identical to
pre-profile renders. An XHTML target opts in per publication target
(`--target-profile NAME=xhtml`); the profile is a serializer switch and does
not touch `heading_ids`/`footnotes` (heading ids are plain attributes —
XML-legal). See [XHTML output profile](#xhtml-output-profile) below.

## XHTML output profile

The pinned Oliver revision carries Oliver's XHTML serializer profile
(`oliver.html.RenderOptions.profile`), which serializes the *same* normalized
document in XML-compatible bytes — same semantics, different markup. By
Oliver contract it emits **fragments only**: no DOCTYPE, no
`<html>/<head>/<body>` wrapper. Boris's layouts own the document wrapper, so an
XHTML *document* means the layout template emits the XML declaration +
`<html xmlns="http://www.w3.org/1999/xhtml">` and the page-body slot receives
the XHTML fragment. The fragment serializer is never given fake wrappers.

The profile **fails closed** on verbatim raw HTML (`error.RawHtmlNotXmlWellFormed`
— never repaired, never rewritten). An XHTML target whose content contains raw
HTML hard-fails the build with the typed error surfaced with page/offset
context in the diagnostics surface; flipping a target to XHTML requires a
raw-HTML sweep of its content first. The same bytes render fine under the
`html` profile.

**Known upstream gap (footnotes):** the pinned Oliver's footnote markers
(`data-footnote-ref`, `data-footnotes`, `data-footnote-backref`) are
hardcoded valueless attributes, so an XHTML target whose content uses
footnotes produces XML that is *not* well-formed — the build does not fail
closed on it (tracked upstream as [drawmeanelephant/oliver#60](https://github.com/drawmeanelephant/oliver/issues/60)).
Until the pinned revision carries the fix, keep footnote use off XHTML
targets; the evidence guard (`zig build test-xhtml-evidence`) verifies
well-formedness on a footnote-free page.

## Cooklang seam (same pin)

Boris consumes Oliver's Cooklang stack through the **same** `.oliver` pin for
the `.cook` input mode. Until oliver#39 merged, the Cooklang stack lived on
Oliver `main` while the renderer extensions were embargoed on the
`boris-markdown-extensions` branch, so Boris carried a second `.oliver_cooklang`
dependency (previously pinned at `bcf167fa`, Oliver main pre-#39). With the
embargo lifted and oliver#39 on `main`, the two revisions converged and the
split dependency was deleted.

The Cooklang parser is a pure typed `Recipe` frontend (ingredients, cookware,
timers, steps, sections, notes, frontmatter fence) — see
[`cooklang-compatibility.md`](cooklang-compatibility.md) for how Boris consumes
it.

## Upgrade procedure (mechanical)

Because Oliver is young and moves quickly, upgrades are a deliberate, boring
process:

1. **Update the pin.** Edit `build.zig.zon`:
   `zig fetch --save https://github.com/drawmeanelephant/oliver/archive/<NEW_COMMIT>.tar.gz`
   (or bump the URL/hash by hand and run `zig build` once to print the expected
   hash). If a new Oliver feature is needed, land it upstream first, then pin
   the commit that contains it.
2. **Run the renderer contract fixtures:** `zig build test-render`.
3. **Run the full suite:** `zig build test` (includes the byte-exact
   `compile.zig` golden `L<h1 id="alpha">Alpha</h1>\n`, the html fixture goldens
   under `test/fixtures/html/`, and `test/fixtures/doc-links/`).
4. **Run the corpus/evidence gates:** `zig build test-publication-conformance`
   and the seeded-fixture harnesses (`test-publication-proof-pack-fixture`,
   `test-publication-touches-fixture`), which pin SHA-256 digests of rendered
   output. A renderer change that alters HTML bytes will fail these — refresh
   the golden hashes only after reviewing the actual output delta.
5. **Review intentional output deltas.** Use the compatibility wall below as
   the checklist; classify any new difference before accepting it.
6. **Commit the new pin** with a note of what changed and which goldens moved.

## Compatibility wall (ApexMarkdown Unified → Oliver)

Boris's previous renderer was ApexMarkdown v1.1.13 Unified via a C host adapter
(`vendor/apex/apex.c`). This migration replaced it with Oliver. A differential
corpus run over all published `content/*.md` bodies (same input through both
engines, using Boris's exact option sets) found **4 of 24 files byte-identical;
20 differing only in the categories below**. The differential also surfaced
and fixed **two genuine Oliver defects** (see rows 9–10), and the
publication-conformance `c01` Textile case pinned a missing GFM strikethrough
to `<del>`, implemented in Oliver as an opt-in extension (row 11). Every
remaining difference is a classified, intended delta or a harmless formatting
choice.

| # | Category | Old (Apex) | New (Oliver) | Classification |
|---|----------|-----------|--------------|----------------|
| 1 | Fenced-code info attribute | `<pre lang="bash"><code>` | `<pre><code class="language-bash">` | Harmless formatting; the `class="language-"` convention is the CommonMark-recommended form. Content that relies on `lang=` styling is updated (none does). |
| 2 | Smart typography | `'` → `’`, `"` → `“ ”` (Unified default) | Source bytes kept literal | Apex extension removed. Oliver keeps author bytes; no Boris contract required smart quotes. |
| 3 | Table captions | `Table: X` / `: X` consumed into `<figure class="table-figure"><table data-caption="X">` | Caption line renders as ordinary paragraph text | Apex extension removed. Caption lines in published content were converted to visible bold lead-ins. |
| 4 | Footnote anchor naming | `fn-<label>` / `fnref-<label>` (e.g. `fn-speed`) | `fn-<n>` / `fnref-<n>` (first-reference order) | Harmless internal naming; footnote links and back-refs are renderer-generated and self-consistent within a page. The rereference scheme (`fnref-N` then `fnref-N-2`, one backref per reference) matches GFM/GitHub's `micromark-extension-gfm-footnote` (which "matches github.com"); Pandoc is number-based like Oliver's `fnref-<n>` but still emits duplicate ids for repeated references — the defect Oliver fixes (see `docs/MARKDOWN-EXTENSIONS.md` §1 provenance). |
| 5 | Footnotes inside definition-list bodies | Ref left as literal `[^label]` text and **no footnote section emitted** | Ref renders as `<sup class="footnote-ref">` and the section renders | **Oliver fixes an Apex gap.** Footnotes are a published Boris construct; they now actually render inside `<dd>` bodies (see `technology-and-rationale.md`). |
| 6 | Paragraph structure | Merged consecutive paragraphs whose next line starts with `**…**`; lazy `</p>` placement | One `<p>` per paragraph (CommonMark-correct) | Oliver standards correction. |
| 7 | Table false-positive | A paragraph containing `—|—|` was misparsed as a table | Plain paragraph | Oliver correct (no delimiter row present). |
| 8 | Images with title | `<figure><img …><figcaption>title</figcaption></figure>` | `<p><img …></p>` | Apex extension (`enable_image_captions`) removed; no published content uses titled images. |
| 9 | Inline content after a link/image | **Dropped** — `[x](/u) and more` rendered `<a href="/u">x</a>` with everything after the link missing | `<a href="/u">x</a> and more` | **Oliver bug fixed** (`5a3f0c6`). Oliver's link/image splice clobbered the trailing text item during discovery; fixed and locked by the `link-trailing-text` fixture upstream. (The initial differential understated this: pages whose first inline link sat early in the body were truncated, so several "formatting" rows were partially affected.) |
| 10 | GFM strikethrough (`~~x~~`) | `<del>x</del>` (Apex GFM) | `<del>x</del>` (Oliver extension, pinned `18dc5ff`) | **Restored for Boris's Textile contract** (`-deleted-` → `~~deleted~~` → `<del>`, `docs/contracts/textile-compatibility.md`). Oliver's markdown dialect gained an opt-in `strikethrough` extension per GFM spec §6.5; CommonMark conformance stays 652/652. |

### Constructs still covered (Boris publishes them; Oliver supports them)

Ordinary paragraphs; ATX and Setext headings (with auto-ids and IAL ids);
emphasis/strong; inline and reference links; inline and reference images; code
spans; fenced and indented code; block quotes; ordered/unordered/nested lists;
thematic breaks; entities; autolinks; raw inline HTML and HTML blocks (Boris's
raw-HTML policy is unchanged — trusted author content passes through); GFM
tables; hard/soft breaks; escaping; Unicode; footnotes; definition lists; GFM
strikethrough (two-tilde runs, GFM spec §6.5).

### Apex-only constructs no longer rendered (not used by published content)

Math, callouts (`> [!NOTE]`), task lists, fenced divs (`:::`), bracket spans,
critic markup, smart typography, and image/table captions. The
only place these were exercised in content was the renderer showcase guide
(`content/guides/oliver-markdown.md`), which this migration rewrote to describe
Oliver. `> [!NOTE]`-style lines now render as ordinary blockquotes. If a future
Boris feature genuinely needs one of these, implement the smallest principled
feature in Oliver (with tests) and consume it through the seam — never a
Boris-side parser hack.

## Determinism

Oliver's core (source, document, diagnostics, frontends, renderer) has no
clock, network, filesystem, environment, thread, or global-state behavior, so
identical input produces byte-identical HTML and builds do not depend on
iteration or hash order. `src/render.zig` allocates through the caller's
Whiteboard arena and writes to a single writer; nothing is cached or
retained between documents. The evidence-chain harnesses and the two-build
byte comparison in this migration confirm repeated full builds are
byte-identical.

## Raw HTML policy

Unchanged: raw HTML in trusted author content passes through unescaped
(CommonMark HTML blocks + inline HTML). Boris does not sanitize; the boundary
between trusted and untrusted content is a Boris policy concern, not a
renderer concern. Fenced code is always escaped.

## Diagnostics and errors

Oliver reports input-size violations as `error.InputTooLarge` before any
markup interpretation; the seam also surfaces `OutOfMemory` and writer
failures. Boris maps these onto its own render → publication-failure path.
There is no renderer diagnostic language to surface: markup interpretation is
lenient (CommonMark), and Boris's own pre-render validators own author-facing
diagnostics.
