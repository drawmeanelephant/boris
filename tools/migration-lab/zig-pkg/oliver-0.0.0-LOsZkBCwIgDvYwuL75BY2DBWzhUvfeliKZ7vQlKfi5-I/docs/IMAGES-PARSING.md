---
published_at: 2026-08-12T00:00:00Z
summary: Contract for the inline-images slice of Oliver's Markdown frontend, derived from CommonMark section 6.7: implemented.
---

# Oliver Inline Parsing: Images

**Status: implemented.** This document is
the contract for the inline-images slice of Oliver's Markdown frontend,
derived entirely from the CommonMark specification (0.31.2) and Oliver's
own docs. It fixes, in one place: the `![`-opener algorithm (from §6.7 and
the appendix's *look for link or image* procedure), how an image
description's inlines flatten to the `alt` string, the document-model
shape for `alt`, and the reserved metadata extension point
(`Data.attrs`). It mirrors how docs/INLINE-PARSING.md was the emphasis
contract, and how docs/DOCUMENT-MODEL.md records every model decision.

Clean-room note: only specification text (the CommonMark 0.31.2 `spec.txt`
and the numbered HTML) and Oliver's own docs were consulted. No parser
implementation source was read, searched, or imitated.

---

## 1. The spec text (§6.7, quoted)

> Syntax for images is like the syntax for links, with one difference.
> Instead of [link text], we have an [image description].  The rules for
> this are the same as for [link text], except that (a) an image
> description starts with `![` rather than `[`, and (b) an image
> description may contain links.  An image description has inline elements
> as its contents.  When an image is rendered to HTML, this is standardly
> used as the image's `alt` attribute.

and, on rendering:

> Though this spec is concerned with parsing, not rendering, it is
> recommended that in rendering to HTML, only the plain string content of
> the [image description] be used.  Note that in the above example, the
> alt attribute's value is `foo bar`, not `foo [bar](/url)` or
> `foo <a href="/url">bar</a>`.  Only the plain string content is
> rendered, without formatting.

**Section-numbering note (recorded divergence).** The repo's established
convention (the link milestone, docs/INLINE-PARSING.md, and this
mission's brief) cites links as §6.6 and images as §6.7. In the numbered
0.31.2 HTML the sections are actually *6.3 Links* and *6.4 Images*
(`spec.txt` headers carry no numbers). Oliver keeps the repo convention
(§6.6 links, §6.7 images) for continuity with existing docs; the example
numbers cited here are the real 0.31.2 example numbers (572–593 for the
images section).

## 2. The `![`-opener algorithm (from the spec's appendix)

The appendix, *An algorithm for parsing nested emphasis and links*, is the
normative algorithmic contract. Its relevant points, applied to links and
images:

- When inline parsing hits a `[` **or** `![`, a delimiter of that type is
  pushed onto the delimiter stack. All are "active" to start.
- When a `]` is hit, the *look for link or image* procedure runs: look
  backwards from the top of the stack for the **nearest** `[` or `![`
  opener.
  - none found → literal `]`;
  - found but **inactive** → remove it, literal `]`;
  - found and **active** → parse ahead for a valid inline
    link/image (in this slice: `(...)` immediately after the `]`; the
    reference forms need §4.7 and defer);
    - not valid → remove the opener, literal `]`;
    - valid → form the link/image node whose children are the inlines
      after the opener, run emphasis processing on them as a fresh scope,
      remove the opener, and — **only when the construct is a link, not an
      image** — mark every earlier `[` delimiter *inactive*.
- Images never inactivate anything: an image description may contain
  links and images, so `![foo [bar](/url)](/url2)` and
  `![foo ![bar](/url)](/url2)` both form the outer image (spec examples
  574, 575). A formed link inactivates earlier `[`s precisely so that
  links cannot contain links (`[foo [bar](/uri)](/uri)` leaves the outer
  brackets literal, spec example).

### Oliver's mapping onto the existing seam

The link milestone already implements this as a *discovery pass* between
scan and emphasis match, with a bracket stack. Images extend that same
pass — no parallel pipeline:

- **Scan.** `![` (unescaped `!` immediately followed by an unescaped `[`)
  becomes a `bracket` item with `ch = '!'` whose span covers both bytes;
  unescaped `[`/`]` become bracket items with `ch = '['` / `']'` as today.
  Escaped `!` or `[` at the boundary is not an opener: `\![foo]` is a
  literal `!` (the `!` is escaped), `!\[foo]` has an escaped `[` (spec
  examples 592, 593).
- **Discovery.** The stack holds one entry per open `[`/`![` bracket item
  (an out-list index plus its active state). A `]` consults the nearest
  entry:
  - inactive or no valid `(...)` → pop, literal `]`;
  - active + valid `(...)` → splice the bracket range plus the consumed
    `(...)` items into a single `link`/`image` item; drop the matched
    opener and everything trapped above it; if a **link** formed, mark
    every earlier `[` (never a `![`) inactive.
- **Match/emit.** Link and image items are opaque to the delimiter stack;
  a link's text children are matched as a fresh inline scope (existing
  behavior), and an image's description children are matched as a fresh
  scope and then **flattened to the `alt` string** (§3).

### The active/inactive mechanics, exactly

The appendix's inactive rule has a subtle consequence the naive
"clear the stack" approach misses: an inactive `[` can remain on the
stack *above* a live `![` and intercept a later `]` that would otherwise
reach that `![`. Example:

```
![foo [bar [baz](/u)](/u2)](/u3)
```

The inner `[baz](/u)` link forms first and inactivates the `[bar`
opener. The next `]` finds the inactive `[bar` and dies as a literal `]`
— it must **not** reach the `![` below it. A faithful implementation
therefore keeps the inactive marker and checks the *nearest* opener's
activity, exactly as the appendix describes.

Oliver implements the marker with a **monotone out-position check** that
is O(1) instead of O(stack): a `[` entry is inactive iff some link has
formed with an opener at a *larger* out position (out positions are
monotone over the pass — a construct item replaces its opener's position
and later items sit strictly after). A single running
`max_link_opener_out` value decides every check; nothing is re-marked, so
hostile inputs like `[[[a](u) [[b](v) [[c](w)...` (which would otherwise
re-mark a growing inactive pile per link — quadratic) stay linear. `![`
entries are never subject to the check. This reproduces the appendix's
*look for link or image* step for step. The reference-style branches
(full/collapsed/shortcut for `![` openers) are implemented on the same
stack via the §4.7 definition table — the separate contract
docs/REFERENCE-IMAGES.md, written before that code.

## 3. Alt: the model decision

**Decision: option (b).** `.image` carries an **arena-owned `alt`
string** (with `src` and optional `title`, mirroring `data.link`); the
image node is a **leaf inline with no children**. The description's
inlines are matched and flattened at parse time; the tree is discarded.

Justification against the DOCUMENT-MODEL invariants:

- **The renderer never resolves dialect escapes.** Under option (a)
  (children kept, renderer flattens), the renderer would have to walk
  emphasis/strong/link/code-span children and reassemble a plain string
  — text assembly and escape semantics pushed into the renderer. The
  invariant exists precisely to keep dialect semantics out of the
  renderer. Option (b) matches the established pattern: `code_span` and
  `link` payloads are arena-owned copies whenever normalization cannot
  be a source slice (docs/DOCUMENT-MODEL.md, invariant 5).
- **Leaf inlines have no children.** The spec says the description's
  content is *not* rendered structurally — only its plain string content
  is. A node that carries structure the spec says to discard is the wrong
  shape. `.image` joins `text`, `code_span`, and the breaks as a leaf.
- **Spec fidelity.** "Only the plain string content is rendered, without
  formatting" is a statement about the *value* of `alt`, not about a
  subtree. The model should say the same thing the spec says.

### What "plain string content" means, inline kind by inline kind

The description is first parsed as inline elements (it "has inline
elements as its contents"), then flattened. Oliver's flattening runs the
same match phase as paragraph inlines (delimiter stack, rules 1–12) on
the description, then walks the items in document order:

| inline kind | contributes to `alt` | source |
| --- | --- | --- |
| `text` | the text with backslash escapes resolved (§2.4) | §2.4, link-text rule "with backslash-escapes in effect" |
| `emphasis` / `strong` | nothing (delimiters dropped), children flattened | `![foo *bar*]` → `foo bar` (spec example 573) |
| `code_span` | the normalized span content (backticks dropped) | chosen behavior; the span's content *is* its plain string content |
| `link` | the flattened link text | `![foo [bar](/url)](/url2)` → `foo bar` (spec example 575) |
| `image` | the inner image's own flattened description | `![foo ![bar](/url)](/url2)` → `foo bar` (spec example 574) |
| `soft_break` / `hard_break` | `\n` (the line ending) | chosen behavior; a break's plain string content is the line ending |
| leftover (unconsumed) delimiter | the literal `*`/`_` bytes | §6.2: unmatched delimiters are literal text |
| unconsumed bracket | the literal `[`/`]`/`![` bytes | spec: unmatched brackets stay literal |

Recorded chosen behaviors (no spec example decides them):

1. **Breaks flatten to `\n`** — soft and hard both. The hard-break *marker*
   (trailing spaces or backslash) is consumed by the existing break
   analysis and is not content, exactly as in normal emission; the plain
   string content of a break is the line ending itself.
2. **Code spans flatten to their §6.1-normalized content** (backticks
   dropped, line endings already spaces) — the content *is* the plain
   string content.
3. **Empty description → `alt=""`**, the attribute always present and
   possibly empty (`![](/url)`, spec example 581).

The flattening walk is iterative (an explicit work stack of
scope-frames), so a hostilely deep image description (`![![![...`) cannot
overflow the call stack — the same discipline the renderer and iterator
already follow.

## 4. Rendering (`<img>`)

- `<img>` is a **void element**: `<img src="..." alt="..." title="..." />`
  under `RenderOptions.void_trailing_slash` (default), `<img ...>` when
  disabled — the existing `<br />` policy, applied.
- Attribute order is fixed: `src`, `alt`, then `title`.
- `src` uses the **same percent-encoding + HTML-escaping policy as link
  `href`** (docs/ARCHITECTURE.md): encode everything except alphanumerics
  and `-_.~!*'(),;:&=+$#@/%?`, then `&` → `&amp;` inside the attribute.
- `alt` is **always emitted**, even when empty; `title` only when
  present. Both are HTML-escaped like text (`&` `<` `>` `"`, NUL →
  U+FFFD) — spec example 572's `title="train &amp; tracks"` is the
  pattern for both.
- `.image` is a leaf: the renderer writes the whole void tag on enter and
  never pushes a close frame.

## 5. The metadata extension point (`Data.attrs`)

docs/DOCUMENT-MODEL.md already reserves `Data.attrs` — an *ordered*
attribute list — for Textile classes/ids/styles and future image
metadata. This mission defines:

- **Spec metadata** (`src`, `alt`, `title`) lives in `Data.image`
  (arena-owned strings), mirroring `Data.link`.
- **`Data.attrs` is the reserved extension point** for future *extension*
  metadata — the roadmap's classes, ids, width/height, and custom
  attributes. No extension syntax is invented in this mission.
- The extension point is shaped for the anticipated kinds by being an
  ordered list of name/value pairs (deterministic rendering requires
  deterministic ordering; the renderer will emit them in a fixed
  documented order). Nothing in the parser or renderer today reads
  `Data.attrs`; it is reserved, not implemented.

## 6. What this slice does and does not implement

Implemented: the inline image `![alt](dest "title")` in paragraphs and
headings; destinations and titles parsed identically to links
(`<...>`/bare destinations, `"`/`'`/`(...)` titles, separators, and the
shared §6.6 DoS guards — paren depth 32, per-component scan cap 2048
bytes); alt flattening per §3; `<img>` rendering per §4. The
reference-style forms (`![alt][label]`, `![alt][]`, `![alt]`) are also
implemented, resolved through the §4.7 definition table with the same
full→collapsed→shortcut ordering and alt flattening as their inline
counterparts (docs/REFERENCE-IMAGES.md); the §6.4 reference-image spec
examples 582–591 verify byte-for-byte.

Entities and Textile remain out of scope. Autolinks and raw HTML now
participate in image-description flattening: autolinks contribute their raw
label, while raw HTML contributes its source bytes per docs/RAW-HTML.md.

## 7. Verification and test plan

1. Verify the inline examples byte-for-byte through the CLI
   (`zig build run -- render --from markdown`) *before* writing fixtures:
   examples 572, 574, 575, 578, 579, 580, 581 (and 592, 593 in their
   literal, no-definition form).
2. Lock each verified example as a fixture
   (`tests/fixtures/markdown/image-*.md` + `.html`), plus: nested
   images, image-in-link (`[![moon](moon.jpg)](/uri)`, spec example),
   alt flattening (emphasis and code span), image in heading, image in
   emphasis, code-span precedence (`` ![foo`](/uri)` `` keeps the span so
   the `]` never closes), unclosed → literal, escaped `!`/`[`.
3. Unit tests: image structure/spans/payloads, alt flattening per §3,
   nesting (image-in-link, link-in-image, image-in-image), escape
   boundaries, precedence with emphasis and code spans, and the shared
   DoS guards (`![a](`-style smoke joined to the existing adversarial
   shapes).
4. Renderer-only test: hand-built `.image` nodes (empty alt, title
   absent, percent-encoded src, escaping, void-slash toggle).
5. Quality gate: `zig fmt --check`, `zig build`, `zig build test` green;
   the whole pre-existing suite must pass unchanged.

## 8. Recorded ambiguities and chosen behaviors (summary)

1. **Breaks in the description flatten to `\n`** (soft and hard) — chosen,
   no spec example.
2. **Code spans flatten to their normalized content** — chosen, no spec
   example.
3. **Empty description → `alt=""`**, attribute always present — spec
   example 581.
4. **Section numbering**: repo convention says images are §6.7; the
   numbered 0.31.2 HTML says §6.4. Oliver keeps the repo convention and
   records it here.
5. **Inactive brackets are kept and checked, not cleared** (appendix
   semantics, O(1) monotone check) — so a dead `[` above a live `![`
   intercepts a `]`, exactly as the appendix's *look for link or image*
   requires.
6. **`src` percent-encoding** reuses the link `href` policy (a renderer
   policy the spec leaves open; recorded in docs/ARCHITECTURE.md).
