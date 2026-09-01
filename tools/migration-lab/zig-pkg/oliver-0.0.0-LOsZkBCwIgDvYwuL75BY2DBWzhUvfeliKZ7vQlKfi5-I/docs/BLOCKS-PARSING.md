---
published_at: 2026-08-12T00:00:00Z
summary: Contract for Oliver's container-block algorithm: block quotes and lists share the container stack (CommonMark section 5).
---

# Oliver Block Parsing: Container Blocks (Block Quotes, Lists)

**Status: implementation contract. Block quotes and lists share the
container stack; thematic breaks and Setext headings now close the first
leaf-block precedence rung.**
This document derives Oliver's container-block algorithm from the
CommonMark spec (§5 "Container blocks and leaf blocks", §5.1 "Block
quotes", §5.2 "List items", §5.3 "Lists", and the appendix "A parsing
strategy"), quoted and paraphrased. Implementation follows this document
block quote first (§5.1), then list items and lists (§5.2/§5.3); the
architecture is designed up front so both fit the same seam.

The container milestones are verified with the sectioned scorecard. After the
thematic-break/Setext rung, the canonical 0.31.2 corpus scores 21/25 for block
quotes, 32/48 for List items, and 21/27 for Lists; remaining failures required
the not-yet-implemented code or HTML block families, which have since landed
(docs/FENCED-CODE.md, docs/ENTITIES.md, docs/HTML-BLOCKS.md). Block quotes are
now 25/25 and List items 48/48.

---

## 1. The spec's model

CommonMark divides blocks into two kinds (spec, "Container blocks and
leaf blocks"):

- **Container blocks** — block quotes, list items, and lists — *contain*
  other blocks.
- **Leaf blocks** — paragraphs, headings, code blocks, thematic breaks,
  HTML blocks — cannot.

The appendix ("A parsing strategy") describes the phase-1 algorithm that
Oliver follows: the document is a tree of blocks; the **last child of a
block is normally open** (later lines can alter it). Processing is a
stack:

1. **Match continuation.** Iterate the open blocks from the root down
   through last children. Each container imposes a condition the line must
   satisfy to keep it open (a block quote needs a `>` marker; a list item
   needs the content indentation; a paragraph needs a non-blank line).
   Markers are *consumed* as they match. Unmatched blocks are not closed
   yet — the line may be a **lazy continuation**.
2. **Open new blocks.** After consuming the matched markers, look for new
   block starts (a `>` for a block quote, a list marker, an ATX heading,
   ...). A new block start closes the unmatched blocks from step 1, then
   opens as a child of the last matched container.
3. **Incorporate the remainder.** The rest of the line (after markers and
   indentation are consumed) is added to the deepest open leaf — a
   paragraph's text, a code block's content, etc.

Reference link definitions are detected at paragraph close (§4.7, already
landed) and inlines are deferred to phase 2 (already landed).

## 2. Block quotes (§5.1)

**Marker.** A block quote marker, optionally preceded by up to three
spaces of indentation, is (a) `>` followed by a space of indentation, or
(b) a single `>` not followed by a space of indentation. The consuming
rule: skip up to three leading spaces, take `>`, then consume *one*
following space or tab if present. Four leading spaces is not a marker
(that is an indented code block).

**The three rules:**

1. **Basic case.** Prepending a marker to each line of a sequence of
   blocks yields a block quote containing those blocks. So `> # Foo` +
   `> bar` + `> baz` is a block quote containing a heading and a
   paragraph.
2. **Laziness.** Deleting the marker from one or more lines of a block
   quote — when the next non-space/tab character after the (deleted)
   marker would have been **paragraph continuation text** — leaves the
   quote's content unchanged. Paragraph continuation text is text that
   would parse as part of a paragraph's content but does not occur at the
   paragraph's beginning: i.e., it is *not* the start of a block that can
   interrupt a paragraph.
3. **Consecutiveness.** Two block quotes cannot be adjacent without a
   blank line between them.

**Consequences, from the spec's examples (targets for `--section "Block
quotes"`):**

- The space after `>` may be omitted: `># Foo` is a marker.
- Markers may be preceded by ≤3 spaces; 4 spaces is indented code.
- Laziness: `> bar` then `baz` is one paragraph `bar\nbaz` inside one
  quote; `> # Foo\n> bar` then `baz` keeps the heading and paragraph
  together.
- Laziness applies only to *paragraph continuation*: `> foo` then `---`
  is a quote + thematic break (the `---` would start an interruptible
  block, so the quote closes); `> - foo` then `- bar` is a quote + a new
  list (a list item can interrupt, so no laziness).
- An indented/fenced code block's continuation lines cannot be lazy.
- A quote can be empty (`>` alone or with blank marker lines); it can
  have initial/final blank *marker* lines (`>\n> foo\n>  `).
- A truly blank line closes the quote: `> foo\n\n> bar` is **two** quotes;
  `> foo\n>\n> bar` is **one** quote with two paragraphs (marker-blank
  lines keep the container open).
- A quote can interrupt a paragraph: `foo\n> bar`.
- Nested quotes: `> > > foo` (markers consumed per nesting level);
  laziness may omit *any* number of initial `>`s on a continuation line
  (`> > > foo` then `bar`).
- An indented code block inside a quote needs five spaces after the `>`:
  four for the code block plus one consumed by the marker.

**Interruption.** A block quote *can* interrupt a paragraph (§5.1 example
`foo\n> bar`). Interruption happens at step 2 of the algorithm: the
unmatched paragraph closes, the quote opens under the last matched
container.

## 3. List items (§5.2)

**Markers.** A bullet list marker is `-`, `+`, or `*`. An ordered list
marker is 1–9 digits followed by `.` or `)`. A marker may be preceded by
up to three spaces. The marker is followed by 1 ≤ N ≤ 4 spaces of
indentation (or a blank line, rule 3).

**The rules:**

1. **Basic case.** A list item is a marker *M* of width *W* plus N spaces
   of indentation, followed by blocks whose first line starts with a
   non-space, with subsequent lines indented *W + N* spaces. The content
   indentation is what matters: the position of the first non-space after
   the marker determines how far later blocks must be indented to stay in
   the item (not the absolute column — nesting shifts columns).
2. **Indented-code first block.** If the item's first block is an
   indented code block, the content is preceded by *one* space after the
   marker (i.e., indent by W+1, then the code block's own 4 spaces).
3. **Blank-line start.** An item may start with a blank line; the
   required indentation is then W+1 regardless of trailing marker spaces.
   At most one blank line: `-\n\n  foo` is an empty item + a paragraph.

**Exceptions:** a list item interrupting a paragraph must not begin with a
blank line, and (if ordered) must start at number 1. A thematic break line
is never a list item (`-` alone is an empty item, but `- - -` is a
thematic break). An empty list item cannot interrupt a paragraph.

## 4. Lists (§5.3)

- A list is one or more list items of the **same type**: same bullet
  character, or same ordered delimiter. Changing the bullet or delimiter
  starts a new list.
- The ordered list's `start` comes from its first item's number;
  subsequent numbers are ignored.
- **Tight vs loose.** A list is loose if any item pair is separated by a
  blank line, or if any item directly contains two block elements with a
  blank line between them. Paragraphs in a loose list render with `<p>`;
  in a tight list they render without.
- A list can interrupt a paragraph (bullet lists and ordered lists
  starting at 1).

## 5. Oliver's algorithm (derived)

Phase 1 keeps a **container stack** plus **one open leaf** (a paragraph or
heading under construction). This replaces today's flat
single-paragraph loop while preserving everything that already works
(definitions at paragraph close, deferred inlines, ATX headings).

```text
containers: [document, block_quote*, (future) list, list_item, ...]
leaf:       the open paragraph/heading inside the last container, if any

per line:
  A.  Match: walk containers top-down; each block quote consumes one
      marker (≤3 leading spaces + '>' + optional following space); a list
      item consumes its content indentation. On a blank line the item
      consumes up to that indentation, preserving only excess spaces for an
      open literal leaf. Stop at the first container whose condition fails.
      Markers consumed so far are stripped from the line cursor.
  B.  Blank line (cursor empty): close the leaf paragraph; close every
      container below the last matched one (a blank line without its
      marker closes a container — rule 3, consecutiveness); keep matched
      containers open (marker-blank lines inside quotes stay).
  C.  Non-blank, some containers unmatched:
      - If the leaf is an open paragraph and the remainder is *paragraph
        continuation text* (does not start an interruptible block), this
        is a lazy continuation: append the remainder to the paragraph,
        keep the unmatched containers open.
      - Else close the leaf and the unmatched containers, then fall into
        step D for the remainder.
  D.  New block starts on the cursor: a `>` opens a block quote
      (interrupts); an ATX heading opens (interrupts); (future) list
      marker, thematic break, fences, setext underline, HTML blocks.
      A block quote opened here becomes the new last container; its marker
      is consumed and the cursor re-examined.
  E.  Incorporate the remainder into the deepest open block: open a
      paragraph (or other leaf) under the last container if none is open,
      else append to the open paragraph.
```

**Paragraph-continuation-text hook.** Step C depends on knowing which
lines would *start an interruptible block*. Oliver keeps a small predicate
`startsInterruptingBlock(cursor)` that grows with each block milestone.
It recognizes `>` (block quote), `#`-ATX headings, fenced-code openers,
thematic breaks, and list markers (`- `, `+ `, `* `, and `1. `, with the
§5.2 exceptions) as interrupting starts; everything else is continuation text. Setext underlines
transform only a paragraph at the same matched container depth and therefore
never act through a lazy/missing container marker (docs/LEAF-BLOCKS.md).

**Interruption rule summary** (implemented vs pending):

| block start | interrupts paragraph? |
| --- | --- |
| block quote `>` | yes |
| ATX heading `#` | yes |
| thematic break | yes |
| list item | yes, with §5.2 exceptions |
| fenced code | yes |
| indented code | no |
| HTML block (all seven types) | types 1–6 yes; type 7 no (§4.6) |
| setext underline | transforms the open paragraph at matched depth |
| link reference definition | no (§4.7, landed) |

**Nesting and spans.** Each block quote node's span is the union of its
lines' content (markers stripped). Leaf spans are unchanged by
containers: a paragraph inside a quote has the same span shape as one at
top level, but its lines have already been marker-stripped, so text nodes
slice the stripped content. Because the model requires source slices for
`data.text`, marker stripping must not copy: the line cursor is a
`(start, end)` offset pair into the source, so a stripped line is a
sub-slice. (Marker columns are removed from the *leaf* span, never from
the source — the same approach the ATX closing-sequence handling already
uses.)

## 6. Implementation order

1. **Block quotes (§5.1)** — this milestone. Introduce the container
   stack, the marker matcher, laziness, blank-line handling, and
   interruption; add `block_quote` to the document model and
   `<blockquote>`/`</blockquote>` to the renderer; definitions and inline
   parsing inside quotes work unchanged (phase-2 jobs carry the node, and
   definitions are document-global per §4.7).
2. **List items and lists (§5.2/§5.3)** — implemented. Extends the same stack
   with item content-indentation matching, same-type merging, tight/loose
   tracking, and `<ul>`/`<ol>` rendering. This also unlocks the
   quote-in-list and list-in-quote examples.
3. **Leaf-block precedence rung** — implemented: thematic breaks (§4.1) and
   Setext headings (§4.3), including their precedence over list markers and
   lazy-container interaction (docs/LEAF-BLOCKS.md).
4. **Code leaves** — fenced code (§4.5) is implemented as an open leaf that
   ends at its closer or containing-block boundary (docs/FENCED-CODE.md).
   Indented code (§4.4) followed with the tab/virtual-column design it
   requires (docs/ENTITIES.md's sibling M3). HTML blocks (§4.6) — all seven
   types, per docs/HTML-BLOCKS.md — are implemented as an open leaf: types
   1–5 end at their matching terminator on the line, types 6/7 at a blank
   line, following the already-decided verbatim raw-HTML policy.

## 7. Chosen behaviors and divergences

- **Tabs expand to four-column tab stops for block structure.** A tab in
  leading indentation or after a marker is consumed by columns (§2.1),
  and a partially consumed tab stays as the view's first byte with a
  mid-tab column, so subsequent whitespace arithmetic measures from the
  same absolute tab stop. Content bytes are never expanded; a partial tab's
  leftover columns become spaces in indented-code content. The full Tabs
  section and the indented-code/quote/list interactions conform.
- **Block quotes are containers, not leaves.** The model adds
  `block_quote` as a container tag (children: blocks); DOCUMENT-MODEL
  invariants are updated accordingly.
- **Scorecard targets.** Block quotes 0/25 → the 17 examples that depend
  only on quotes/headings/paragraphs/definitions pass immediately; the
  remaining 8 (indented/fenced code inside quotes, thematic breaks, lists
  inside/next to quotes) flip as the leaf-block and list milestones land.
  `--section "Block quotes" --gate` becomes the milestone's CI gate once
  it hits 25/25.

## 8. Verification plan

- `zig build spec-conformance -- spec.txt --section "Block quotes"` as
  the primary oracle (per-example pass/fail with expected-vs-actual
  diffs).
- Fixtures: `quote-*.md`/`.html` pairs for every rule shape above (basic,
  omitted space, 3-space indent, lazy, marker-blank, empty, two-vs-one
  quote, interruption, nesting, deep laziness), registered in
  `tests/fixtures_test.zig`.
- Unit tests: span assertions (quote span = union of stripped lines,
  nested quote spans, paragraph spans inside quotes), and the container
  stack's marker consumption.
- Renderer: hand-built `block_quote` documents render `<blockquote>`/
  `</blockquote>\n`; list documents render `<ul>`/`<ol>` and use the
  tight/loose paragraph framing rules; nested containers compose naturally.
- Regression: the full suite (68 tests) stays green — paragraphs,
  headings, definitions, and all inline behavior unchanged outside
  quotes.
