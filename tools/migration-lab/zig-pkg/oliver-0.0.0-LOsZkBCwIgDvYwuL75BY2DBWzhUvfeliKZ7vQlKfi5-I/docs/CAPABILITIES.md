---
published_at: 2026-08-14T00:00:00Z
summary: What Oliver parses and renders today on main: the user-facing overview of frontend capabilities.
---

# Oliver capabilities

What Oliver parses and renders today on `main`. The full design
contracts live in the per-frontend documents (see the
[docs home](index.html)); this page is the user-facing overview.

## Frontends at a glance

| frontend | parses into | entry point | conformance |
| --- | --- | --- | --- |
| Markdown | shared `document.Document` | `oliver.parse(..., .markdown, ...)` | CommonMark 0.31.2: **652/652**, 0 mismatches |
| Textile | shared `document.Document` | `oliver.parse(..., .textile, ...)` | Textile fixture wall: fully green |
| Cooklang | typed `Recipe` (own model) | `oliver.cooklang.parse(...)` | canonical corpus: **60/60** |

Markdown and Textile converge into one normalized model and one
renderer. Cooklang deliberately keeps its **own typed model** because
recipe semantics are richer than prose markup — ingredients,
quantities, units, cookware, and timers survive parsing as typed data,
never as decorated text.

## Markdown

Full CommonMark 0.31.2 conformance. Block syntax: paragraphs, ATX and
Setext headings, thematic breaks, fenced and indented code blocks, HTML
blocks (§4.6, all seven types), block quotes, lists (§5.2/5.3) with
nesting, marker-width indentation, and tight/loose tracking, GFM pipe
tables, and link reference definitions (§4.7) with full/collapsed/
shortcut resolution. Inline syntax: emphasis and strong emphasis (§6.2,
the complete rule set), code spans, inline and reference-style links
and images, autolinks (URI and email), raw HTML, hard and soft line
breaks, backslash escapes, and entity and numeric character references
(§2.5).

## Textile

The documented Textile 2 syntax through the shared model: `hN.`, `p.`,
and `bq.` blocks with block attributes; `*`/`#` lists; `@code@`; the
phrase-modifier family (`_x_`, `*x*`, `__x__`, `**x**`, `-x-`, `+x+`,
`^x^`, `~x~`, `%x%`, `++x++`, `--x--`, `??x??`, `ABC(def)`) with
attributes; links (titles, the bracket trick, aliases) and images
(alt/title, link attachment, the alignment/size modifier set); `|a|b|`
tables with cell modifiers, colspan, and rowspan; line attributes;
`==` escaping; character replacements (curly quotes, dashes, ellipsis,
symbols, macros); footnotes; `bc.`/`pre.` code blocks; extended
`bq..`/`bc..` blocks; `dl.` definition lists; `clear.`; and
`notextile.` raw passthrough.

## Cooklang

A typed `Recipe` with exact source spans and structured diagnostics:
ingredients (name, quantity, units, preparation), recipe references
(parsed, **never resolved** — filesystem resolution is a consumer
concern), cookware, timers (named and unnamed), steps with forced line
breaks, notes, sections, `--`/`[- -]` comments, and the YAML front-matter
boundary (raw payload preserved with exact spans — Oliver never parses
YAML). Derived operations over the same model:

- **serialize** — canonical `.cook` output (semantic, idempotent;
  not byte-identical round-tripping)
- **scale** — exact-rational scaling by factor or servings, plus the
  public string primitives `classifyQuantity` / `parseFactor` /
  `scaleAmount` for authored amount text; mixed `1 1/2` is a
  canonical scalable input; fixed (`=`) quantities, timers, cookware,
  and recipe references untouched
- **render** — a deterministic HTML policy: ingredients index,
  timers as `<time>` with ISO-8601 durations, section-aware layout
  (with `--to xhtml` for the XML-compatible fragment profile,
  docs/XHTML.md)
- **menu** — the day/meal view over parsed `.menu` files (sections as
  days, `(YYYY-MM-DD)` dates, reference directives as source text)

## Library and CLI

- **Library**: `@import("oliver")`. `oliver.parse` for Markdown/Textile;
  `oliver.cooklang.parse` plus the derived operations for Cooklang. The
  caller supplies the allocator; results own their arenas; text payloads
  borrow the input bytes (which must outlive the result).
- **CLI**: `oliver render --from <markdown|textile|cooklang>
  [--to <html|xhtml>]`, `oliver serialize --from cooklang`,
  `oliver scale --from cooklang (--factor n[/d] | --servings n)`,
  `oliver menu --from cooklang` — a thin stdin/stdout adapter; all
  semantics live in the library. HTML remains the default; `--to xhtml`
  selects the XML-compatible fragment serialization.

## Go deeper

- [Markdown docs](index.html#markdown-frontend) ·
  [Textile docs](index.html#textile-frontend) ·
  [Cooklang contract](COOKLANG.html)
- [Architecture](ARCHITECTURE.html) · [Document model](DOCUMENT-MODEL.html)
  · [Feature matrix](FEATURE-MATRIX.html) · [Tests](TESTS.html)
