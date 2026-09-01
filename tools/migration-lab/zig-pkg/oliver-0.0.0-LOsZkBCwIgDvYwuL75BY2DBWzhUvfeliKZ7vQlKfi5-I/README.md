# Oliver

A small, freestanding markup parsing and rendering library in Zig.

```text
Markdown ──> normalized typed document ──> deterministic HTML / XHTML
Textile ───> normalized typed document ──> deterministic HTML / XHTML
Cooklang ──> typed Recipe (its own model) ─> deterministic HTML / XHTML policy
```

Oliver is **markup infrastructure**: it parses a byte slice, produces a typed
document (or, for Cooklang, a typed Recipe), and renders it deterministically.
Filesystem, templates, site
graphs, plugins, publication — none of that lives here; consumers build it
around Oliver.

Oliver is a **clean-room implementation** of the *behavior* specified by the
CommonMark specification, the published Textile syntax documentation, and the
published Cooklang specification and canonical test corpus. It
does not study or imitate existing parser implementations. See
[docs/CLEANROOM.md](docs/CLEANROOM.md).

## Documentation

The full documentation lives in `docs/` — [docs/index.md](docs/index.md)
is the home page with a site map, and [docs/nav.json](docs/nav.json) is
the renderer-ready navigation manifest. As a user, start with
[docs/CAPABILITIES.md](docs/CAPABILITIES.md) (what each frontend parses
and renders). As a contributor, start with
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
[docs/DOCUMENT-MODEL.md](docs/DOCUMENT-MODEL.md),
[docs/FEATURE-MATRIX.md](docs/FEATURE-MATRIX.md),
[docs/TESTS.md](docs/TESTS.md), [docs/CLEANROOM.md](docs/CLEANROOM.md),
and [docs/WORK-LEDGER.md](docs/WORK-LEDGER.md). The docs tree itself
publishes to GitHub Pages through `.github/workflows/github-pages.yml`;
see [docs/github-pages.md](docs/github-pages.md) for how to enable and
operate it.

## Status

Implemented so far: paragraphs, ATX and Setext headings, thematic breaks,
fenced code blocks (§4.5, backtick/tilde fences, literal normalized content,
info strings and container composition), indented code blocks (§4.4,
chunks separated by blank lines, trailing blanks dropped, list/quote
composition), tab-stop indentation (§2.1, four-column tab stops for block
structure with literal tab bytes preserved in content), backslash escapes,
hard and soft line breaks, emphasis and strong emphasis (full CommonMark
§6.2 rule set, including the mod-3 rule and `openers_bottom` pruning), code
spans (§6.1, run-length matching with delimiter opacity), inline links
(§6.3, bracket opacity, destination/title syntax, href percent-encoding),
inline images (§6.4, `![alt](src "title")` with alt flattening and `<img>`
rendering), reference links and reference-style images (§4.7 link reference
definitions collected in the block pass; full, collapsed, and shortcut
forms resolved against a Unicode case-folded label map — for `[text]`
links and `![alt]` images alike), block quotes (§5.1) and list items/lists
(§5.2/§5.3) on the container-block stack with nesting, content indentation,
same-type merging, tight/loose tracking, and deterministic `<ul>`/`<ol>`
rendering, autolinks (§6.5, URI and email forms with `mailto:` hrefs,
escapes inert, linear recognition), raw HTML (§6.6,
tags/comments/instructions/declarations/CDATA rendered verbatim), HTML
blocks (§4.6, all seven types: script/pre/style/textarea element blocks,
comments, processing instructions, declarations, and CDATA ending at
their matching terminator, plus block-tag lines and whole-line tags
ending at a blank line — all verbatim), GFM pipe tables (the §4.10
extension in the Markdown frontend: header + delimiter rows, alignment
colons, escaped `\|`, inline-parsed cells, `<table><thead><tbody>`
output — docs/TABLES.md), opt-in Markdown extensions (Pandoc-style
footnotes, definition lists, heading attribute lists, GFM
strikethrough, Obsidian-style `[[wikilinks]]`, `> [!note]` callouts, and
smart typography (`smartypants`) — docs/MARKDOWN-EXTENSIONS.md,
docs/WIKILINKS.md, docs/CALLOUTS.md, docs/SMARTY.md),
shared front matter (YAML `---` / TOML `+++`
sniffed at index 0, stripped before dispatch, parsed into
`ParseResult.metadata` under a bounded, never-faked subset —
docs/FRONTMATTER.md), entity and numeric character
references (§2.5,
named via the WHATWG entities table, decoded in text, link
destinations/titles, info strings, and autolinks but never in code
spans/blocks or as structural syntax), plain
inline text, a shared document model, a deterministic HTML renderer,
Markdown (ATX) and Textile
frontends (`hN.` headings, `p.`/`bq.`, `*`/`#` lists, `@code@`, the
phrase-modifier family `_x_`/`*x*`/`__x__`/`**x**`/`-x-`/`+x+`/`^x^`/`~x~`/`%x%`/
`++x++`/`--x--`,
`"text":url` links, `[alias]url` link aliases with `"text":alias`
references, `!url!` images, `|a|b|` tables with `|_. header|`
cells, `table<mods>.` signatures, colspan/rowspan, and header-alignment
propagation, block attributes (`p(...).`/`hN{...}.`/`bq>.` — style,
class/id, lang, alignment, padding — see docs/TEXTILE-PARITY.md),
`bc.`/`pre.` code blocks (escaped `<pre><code>` vs verbatim `<pre>`),
extended `bq..`/`bc..`/`pre..` signatures that stay active across
blank lines, footnotes (`[N]` references + `fnN.` blocks with
`class="footnote"` links), `bq.:URL` block-quote citations
(rendered as the blockquote's `cite` attribute), the character
replacements (curly quotes, em/en dashes, ellipsis, `(c)`/`(r)`/`(tm)`,
fractions, degree, plus/minus, dimension sign, and the `{...}`
character-macro table — cent, pound, yen, accented letters, bullet,
smileys), `==` escaping
(a lone `==` line passes raw HTML through unformatted; inline
`==...==` suspends all formatting and replacements), `|mods|.`
line attributes (the pipe-delimited form of the block-attribute set,
converging byte-identically with `p<mods>.`), image modifiers
(alignment, sizing `10x20`/`10w 20h`/`20%`, and style/class/padding
on `!url!` images), phrase attributes on every operator
(`*{color:red}x*` → `<strong style="color:red;">`, `_(big)x_` →
`<em class="big">`, `%{style}(class#id)[lang]x%` on `%x%` spans),
`??citation??` (`<cite>`, Hobix), `ABC(def)` acronyms
(`<acronym title="def">`), `dl. term:definition` definition
lists (`<dl>`/`<dt>`/`<dd>`), the `clear.` marker (a lone
`clear.`/`clear<.`/`clear>.` line parks a CSS clear fragment that
the next block folds ahead of its own style), and `notextile.`/
`notextile..` raw passthrough (block content emitted unformatted
and unescaped, `<em>` staying a real tag),
structured diagnostics, and a provisional CLI.
The **Cooklang frontend** (`docs/COOKLANG.md`) is a first-class third
frontend with its own typed Recipe model — not the Markdown/Textile
document IR — preserving ingredient/cookware/timer semantics, quantities
and units as source text, shorthand preparations, recipe references
(parsed, never resolved), steps with forced line breaks, notes, sections,
`--`/`[- -]` comments, and the YAML front-matter boundary (recognized,
raw payload preserved, never faked as parsed YAML). It passes the official
canonical corpus 60/60 (`zig build cooklang-conformance -- canonical.yaml`)
and ships a deterministic Oliver-owned HTML policy
(`src/cooklang_html.zig`) plus `oliver render --from cooklang`.
See [docs/SESSION-1-REPORT.md](docs/SESSION-1-REPORT.md) for the founding
handoff and [docs/FEATURE-MATRIX.md](docs/FEATURE-MATRIX.md) for what is
implemented, planned, and deferred. The emphasis/strong algorithm contract
is [docs/INLINE-PARSING.md](docs/INLINE-PARSING.md), derived from the
CommonMark spec's flanking rules (§6.2); the image algorithm contract is
[docs/IMAGES-PARSING.md](docs/IMAGES-PARSING.md); the reference-style
image contract is [docs/REFERENCE-IMAGES.md](docs/REFERENCE-IMAGES.md);
the autolink contract is [docs/AUTOLINKS.md](docs/AUTOLINKS.md); the raw HTML
contract is [docs/RAW-HTML.md](docs/RAW-HTML.md).
The thematic-break/Setext precedence contract is
[docs/LEAF-BLOCKS.md](docs/LEAF-BLOCKS.md).
The fenced-code open-leaf/model/rendering contract is
[docs/FENCED-CODE.md](docs/FENCED-CODE.md).
The Textile fixture audit — inventory, gaps vs. Textile 2 semantics, and
chosen behaviors for phrase modifiers, links, images, lists, tables, link
aliases, block attributes, code blocks, extended blocks, footnotes,
block-quote citations, character replacements, `==` escaping, line
attributes, and image modifiers — is
[docs/TEXTILE-PARITY.md](docs/TEXTILE-PARITY.md).
The GFM tables extension contract is
[docs/TABLES.md](docs/TABLES.md).
The wikilinks extension contract is
[docs/WIKILINKS.md](docs/WIKILINKS.md).
The callouts extension contract is
[docs/CALLOUTS.md](docs/CALLOUTS.md).
The smart typography extension contract is
[docs/SMARTY.md](docs/SMARTY.md).
The front matter extension contract is
[docs/FRONTMATTER.md](docs/FRONTMATTER.md).
The Cooklang frontend's design contract, source hierarchy, provenance,
model, diagnostics policy, and the Oliver/Boris boundary is
[docs/COOKLANG.md](docs/COOKLANG.md).
Code spans, links, images, autolinks, and raw HTML ride the same
scan → match → emit seam.

## Building and testing

Requires Zig 0.16.0. `zig build test` runs the unit, fixture, and
conformance-harness suites; `zig build spec-conformance -- spec.txt` scores
Oliver against every normative example in the exact official CommonMark
0.31.2 corpus (byte count, example count, and SHA-256 are verified first)
and prints a per-section scorecard. Every example is classified in a
reviewed manifest (docs/COMMONMARK-EXPECTATIONS.md) as supported,
not-yet, or a named divergence; `--gate` fails on any supported regression,
unexpected pass, or changed divergence, so the full corpus is a regression
wall (see docs/TESTS.md for how to fetch the spec).

### Current scorecard: 652/652 — full CommonMark 0.31.2 conformance

Every one of the 652 normative examples passes byte-for-byte (0 not-yet,
0 named divergences). Per-section counts are derived from the harness:

```bash
zig build spec-conformance -- spec.txt
```

| CommonMark 0.31.2 section | score |
| --- | --- |
| Tabs | 11/11 |
| Backslash escapes | 13/13 |
| Entity and numeric character references | 17/17 |
| Precedence | 1/1 |
| Thematic breaks | 19/19 |
| ATX headings | 18/18 |
| Setext headings | 27/27 |
| Indented code blocks | 12/12 |
| Fenced code blocks | 29/29 |
| HTML blocks | 44/44 |
| Link reference definitions | 27/27 |
| Paragraphs | 8/8 |
| Blank lines | 1/1 |
| Block quotes | 25/25 |
| List items | 48/48 |
| Lists | 26/26 |
| Inlines | 1/1 |
| Code spans | 22/22 |
| Emphasis and strong emphasis | 132/132 |
| Links | 90/90 |
| Images | 22/22 |
| Autolinks | 19/19 |
| Raw HTML | 20/20 |
| Hard line breaks | 15/15 |
| Soft line breaks | 2/2 |
| Textual content | 3/3 |
| **Total** | **652/652** |

```bash
zig build test    # run all tests (280 tests)
zig build         # build the static library and CLI into zig-out/
zig build cooklang-conformance   # Cooklang canonical corpus (vendored)
```

### Prebuilt binaries

A rolling `builds` release on this repository carries the current CLI
binary for each supported platform, rebuilt on every push to `main`:

- `oliver-linux-x86_64`, `oliver-linux-aarch64`
- `oliver-macos-x86_64`, `oliver-macos-aarch64`

Download URL (stable, derived from the tag):

```text
https://github.com/drawmeanelephant/oliver/releases/download/builds/oliver-<os>-<arch>
```

`sha256sums.txt` in the same release verifies the assets. The binaries
are ReleaseSafe and statically linked (macOS links only system libSystem).

Every CI-built binary embeds the exact source commit it was built from:
`oliver --version` prints `oliver <version> (commit <full-sha>)`. A
consumer that pins a commit can assert the downloaded binary's reported
commit equals its pin and reject on mismatch — the download URL itself
may move, the byte identity cannot silently drift.

## Library use

```zig
const oliver = @import("oliver");

const result = try oliver.parse(allocator, source_bytes, .markdown, .{});
defer result.deinit();

var aw = std.Io.Writer.Allocating.init(allocator);
defer aw.deinit();
try oliver.html.render(allocator, &aw.writer, &result.document, .{});

// XHTML fragment: same IR, same semantics, XML-compatible serialization
// (docs/XHTML.md). `.profile = .xhtml` on either HTML-family renderer;
// the default remains byte-identical HTML.
try oliver.html.render(allocator, &aw.writer, &result.document, .{ .profile = .xhtml });
```

Cooklang parses into its own typed model through an explicit entry point
(the result is a `Recipe`, not a `document.Document`):

```zig
const cooked = try oliver.cooklang.parse(allocator, recipe_bytes, .{});
defer cooked.deinit();
// cooked.recipe.blocks / .frontmatter / .diagnostics

try oliver.cooklang_html.render(allocator, &aw.writer, &cooked.recipe, .{});
try oliver.cooklang_html.render(allocator, &aw.writer, &cooked.recipe, .{ .profile = .xhtml });

// Canonical serialization: semantic Recipe -> valid .cook (idempotent;
// docs/COOKLANG.md §10).
try oliver.cooklang_serialize.serialize(allocator, &aw.writer, &cooked.recipe, .{});

// Pure scaling: Recipe -> scaled Recipe (exact rationals; fixed `=1`
// quantities, timers, cookware, and recipe references stay untouched;
// docs/COOKLANG.md §11). String primitives (`classifyQuantity` /
// `parseFactor` / `scaleAmount`) classify and rewrite authored amount
// text without a typed Recipe, including mixed `1 1/2`.
var scaled = try oliver.cooklang_scale.scaleRecipe(
    allocator,
    &cooked.recipe,
    .{ .servings = 4 },
);
defer scaled.deinit();

// `.menu` files are valid Cooklang; this is the semantic day/meal view
// over the same parse (docs/COOKLANG.md §12).
var menu = try oliver.cooklang_menu.menuView(allocator, &cooked.recipe);
defer menu.deinit();
// menu.days[i].name / .date / .references — paths stay unresolved.
```

The caller supplies the allocator; the document (or recipe) owns an arena and
borrows the
input bytes; rendering streams to any writer. No global state, no hidden
caches, deterministic output.

## CLI (provisional)

```bash
oliver render --from markdown  < document.md
oliver render --from textile   < document.textile
oliver render --from cooklang  < recipe.cook
oliver render --from markdown --to xhtml < document.md  # XML-compatible fragment
oliver render --from textile  --to xhtml < document.textile
oliver render --from cooklang --to xhtml < recipe.cook
oliver serialize --from cooklang < recipe.cook   # canonical .cook
oliver scale --from cooklang --factor 2 < recipe.cook   # scaled .cook
oliver scale --from cooklang --servings 4 < recipe.cook  # via servings
oliver menu --from cooklang < plan.menu                 # day/meal text dump
oliver --version   # prints version + embedded source commit (CI builds)
```

A thin stdin/stdout adapter — all semantics live in the library.

## Repository layout

```text
build.zig / build.zig.zon   Zig 0.16 build (lib, CLI, tests)
src/                        the library + provisional CLI
tests/                      fixture-driven tests (fixtures live here too)
docs/                       clean-room rules, architecture, feature matrix,
                            document model, test conventions, session report
.github/                    CI gate (workflow) and the draft main-branch
                            protection ruleset (BRANCH-PROTECTION.md)
```

## Design values

Correctness · deterministic behavior · explicit ownership · small
understandable data structures · bounded memory · precise source locations ·
clean parsing/rendering separation · fuzzability · embeddability ·
performance without premature optimization. The core has no host
dependencies: no filesystem, environment, clock, network, or threads — ready
for later WebAssembly embedding.
