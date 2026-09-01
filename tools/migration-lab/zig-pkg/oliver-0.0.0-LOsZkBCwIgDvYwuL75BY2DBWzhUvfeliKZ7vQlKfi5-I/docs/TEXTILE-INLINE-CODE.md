---
published_at: 2026-08-12T00:00:00Z
summary: Clean-room design contract fixing Oliver's Textile @code@ milestone behavior before the parser implementation.
---

# Textile inline code: clean-room design contract

This document fixes Oliver's behavior for the Textile `@code@` milestone
before the parser implementation. It is derived only from published,
user-facing syntax documentation. No Textile parser implementation was
consulted.

## 1. Authoritative syntax

The Hobix **Textile Reference** says that code phrases are surrounded by
at-signs and gives `Convert with @r.to_html@` becoming
`Convert with <code>r.to_html</code>`.

The Movable Type **Textile 2 Syntax** page lists `@code@` among the inline
formatting operators and maps it to `<code>code</code>`. It also says:

- inline operators must be adjacent to their text or punctuation;
- formatting needs an outside whitespace boundary rather than occurring in
  the middle of a word (its generic counterexample is `c*oo*l`);
- `<` and `>` inside an `@...@` section become HTML entities; and
- brackets/braces can force otherwise intraword inline formatting.

Sources:

- Dean Allen, [Hobix Textile Reference](https://hobix.com/textile),
  "Structural Emphasis" / code-phrase example.
- Brad Choate, [Movable Type Textile 2 Syntax](https://movabletype.org/documentation/author/textile-2-syntax.html),
  "Inline Formatting" and its examples.

The references agree on the delimiter and result. They do not give a formal
delimiter algorithm, define an embedded at-sign, demonstrate a multiline
code phrase, or assign backslash an escaping role.

## 2. Oliver's pinned single-line grammar

This milestone recognizes a pair of single-byte `@` delimiters within one
source line. The node span includes both delimiters; its payload is the
verbatim bytes between them.

An opening `@` qualifies when all of these hold:

1. it is at the start of the inline range, or the preceding Unicode code
   point is whitespace or punctuation/symbol;
2. another byte follows it;
3. the following code point is not whitespace; and
4. neither adjacent byte is `@` (empty/doubled delimiter runs are literal).

The first following `@` is the only closing candidate for that opener. It
qualifies when all of these hold:

1. at least one byte lies between the delimiters;
2. the preceding code point is not whitespace and the preceding byte is not
   `@`; and
3. it ends the inline range, or the following Unicode code point is
   whitespace or punctuation/symbol, but the following byte is not `@`.

If that first candidate cannot close, the old opener becomes literal. The
candidate may independently become a new opener. This first-candidate rule
keeps embedded `@` behavior conservative and makes malformed at-sign storms
strictly linear.

For boundary classification Oliver reuses its generated Unicode 13.0
whitespace and punctuation/symbol tables (`Zs` plus the documented control
whitespace; general categories `P` and `S`). Invalid UTF-8 is ordinary text.
This makes punctuation boundaries work consistently for ASCII and Unicode,
while an at-sign pair embedded between Unicode letters stays literal.

Bracket/brace forcing is a separate inline feature and is not inferred by
this slice.

## 3. Conservative choices where the references are silent

- **Same line only.** Each paragraph/heading/quote line is scanned
  independently. `@open` followed by a line ending and `close@` remains
  literal on both lines, with the existing Textile hard break between them.
- **No empty or edge-whitespace code.** `@@`, `@ code@`, and `@code @` are
  literal. This follows the documented requirement that operators sit up
  against their content and avoids inventing trimming rules.
- **No backslash escape.** Neither selected reference gives backslash a role
  for `@`. A backslash is therefore an ordinary punctuation/content byte:
  `\@code@` is a literal backslash followed by a code span, and `@code\@`
  includes the backslash in code. Textile's documented `==...==` escape
  mechanism remains a later opaque-inline milestone.
- **Verbatim payload.** Unlike CommonMark backtick spans, Textile code does
  not normalize spaces or line endings. The payload is arena-owned to honor
  the existing shared `.code_span` contract.
- **Escaped rendering.** The existing shared code-span renderer escapes
  `&`, `<`, `>`, `"`, and NUL. This includes the two characters explicitly
  required by Textile 2 and retains one renderer policy across dialects.
- **Opaque leaf.** Recognized content is emitted as one `.code_span` leaf and
  is never scanned for other Textile phrase modifiers.

## 4. Parser shape and complexity

`src/textile.zig` owns one iterative, line-local scanner. Paragraph lines,
heading content, and the paragraph inside `bq.` all call that same seam.
The scanner keeps at most one pending opener and a text-start offset:

1. scan forward byte by byte;
2. remember a qualifying opener;
3. at the next `@`, either emit the pair or invalidate/reseed the opener;
4. emit untouched source ranges as `.text` nodes.

No recursion, substring rescans, delimiter stack, shared IR change, or
renderer change is required. Time is `O(n)` and scanner auxiliary space is
`O(1)` per line (apart from output nodes and code-payload copies).

## 5. Acceptance contract

Fixtures and unit tests must pin:

- the Hobix basic example shape and HTML escaping;
- multiple code phrases and punctuation-delimited phrases;
- Unicode payloads, Unicode punctuation boundaries, and Unicode intraword
  rejection;
- paragraphs, `h1.`-`h6.` headings, and single-period `bq.` paragraphs;
- opacity of markup-looking bytes inside code;
- unmatched/empty/edge-whitespace/embedded-at-sign literal fallback;
- the conservative same-line rule across Textile hard breaks;
- inert backslashes;
- exact byte spans for preceding text, the full delimited code node, its
  arena-owned payload, following text, and heading/quote code nodes; and
- large alternating matched and near-miss at-sign storms, including two
  deterministic renders of the same parsed document.
