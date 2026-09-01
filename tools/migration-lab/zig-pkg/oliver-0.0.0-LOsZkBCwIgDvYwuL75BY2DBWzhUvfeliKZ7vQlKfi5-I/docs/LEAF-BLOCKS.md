---
published_at: 2026-08-12T00:00:00Z
summary: Implementation contract for CommonMark sections 4.1 and 4.3 leaf blocks: thematic breaks and Setext headings.
---

# Markdown leaf blocks: thematic breaks and Setext headings

**Status:** implementation contract for CommonMark 0.31.2 §4.1 and §4.3.

This design is derived only from the normative CommonMark prose, examples
43–61 (thematic breaks), examples 80–106 (Setext headings), §4.7 link
reference definitions, §5 container rules, and the appendix parsing
strategy. No parser implementation source was consulted.

## Why these features land together

A dash line can satisfy three grammars at once:

- a Setext level-2 underline when an eligible paragraph is open;
- a thematic break when it contains at least three dashes;
- a list marker, especially for spaced forms such as `- - -`.

The normative precedence is one contract:

```text
eligible Setext underline > thematic break > list item
```

Implementing either feature without the other would leave the block parser
with a knowingly wrong interpretation at this shared seam.

## Recognition

### Thematic break (§4.1)

A line is a thematic break when, after zero to three leading spaces, it has
three or more copies of one marker (`-`, `_`, or `*`). Spaces and tabs may
appear between or after the markers; any other byte rejects the construct.
The marker kinds cannot mix.

The line interrupts an open paragraph. It is also an interrupting block for
container laziness: a missing `>` or list-item indentation cannot turn a
thematic break into paragraph continuation text.

The normalized node is a payload-free `.thematic_break` leaf block. It is
not an HTML-shaped node; the HTML renderer chooses `<hr />` or `<hr>` from
its explicit void-element option.

### Setext heading (§4.3)

An underline is one or more `=` bytes or one or more `-` bytes, preceded by
zero to three spaces and followed only by spaces or tabs. Internal whitespace
is not allowed. `=` produces level 1 and `-` produces level 2.

An underline has meaning only when an eligible paragraph is already open at
the same matched container depth. The paragraph's first visible content line
must have at most three leading spaces. A one- or two-dash underline is valid
even though it is too short to be a thematic break.

Leading link reference definitions are handled before eligibility:

- definitions are registered document-wide;
- they are excluded from heading content;
- a paragraph made entirely of definitions is not heading content.

Thus `[id]: /url`, `name`, `===` registers `id` and emits an h1 for `name`.
But `[id]: /url`, `===` has no heading content; the underline remains visible
paragraph text because `=` is not a thematic-break marker.

## Container interaction

The existing phase-1 container stack is retained.

1. Match open block-quote/list/list-item containers and consume their
   markers or content indentation.
2. If a container did not match, apply the existing lazy-continuation test.
   Thematic breaks are interrupting; Setext underlines are never allowed to
   transform a paragraph through a missing container marker.
3. Open any new block-quote markers.
4. Before opening list markers, stop when the remainder is a thematic break
   or an eligible Setext underline.
5. Transform the paragraph for Setext first; otherwise emit a thematic
   break; only then consider list markers.

When a list item fails to match, the list container can remain temporarily
open while the parser decides whether the line begins a sibling item. A
thematic break is explicitly excluded from that sibling test. If it occurs at
the list's depth, the dangling list closes before the break is appended, so a
leaf block is never added directly under `.list`.

Marked underlines still work inside containers (`> Foo` then `> ---`, or
`- Foo` then an appropriately indented underline). An unmarked `---` after a
quoted/list paragraph closes the unmatched container and becomes a thematic
break outside it, as required by the laziness rule.

## Inline phase and spans

Setext content can span multiple source lines. Its pending inline job keeps
the content line references rather than flattening or copying them. The
normal inline discovery/match/emission pipeline then handles code spans, raw
HTML, links, images, references, emphasis, and line breaks exactly as it does
for paragraphs.

The Setext inline whitespace contract is:

- leading spaces/tabs are stripped from each content line under the shared
  soft-break rule;
- trailing line whitespace follows normal break analysis;
- the last content line does not create a break into the excluded underline;
- consequently, a final backslash before the underline remains literal.

The heading node span starts at its first non-definition content line and
ends at the end of the underline line (excluding its line terminator). Inline
children cover only content bytes. A thematic-break span covers its marker
line after enclosing container markers have been stripped.

The same last-line rule fixes a paragraph edge case: a terminal backslash
with no following content line remains literal (CommonMark example 644)
instead of disappearing as a hard-break marker with nowhere to break.

## Complexity and verification

Each physical line receives one reverse thematic-break summary. Nested
container views then classify any suffix in constant time, avoiding repeated
rescans of deep `- ` chains. Setext eligibility scans only a leading run of
reference definitions and immediately consumes the first eligible underline,
so it cannot repeatedly rescan a growing ordinary paragraph. Parsing and
rendering remain iterative.

Verification includes:

- byte-exact fixtures for simple, spaced, malformed, multiline, indented,
  list/quote, reference-definition, and final-backslash cases;
- AST and exact-span unit tests;
- renderer tests for both void-element profiles;
- a deterministic 10,000-cycle heading/break workload plus a 20,000-level
  list/thematic near-miss;
- the full CommonMark 0.31.2 scorecard.

Current canonical scorecard targets are 18/19 for thematic breaks and 25/27
for Setext headings. Every remaining failure requires the deliberately
pending indented-code-block feature; none is silently skipped.
