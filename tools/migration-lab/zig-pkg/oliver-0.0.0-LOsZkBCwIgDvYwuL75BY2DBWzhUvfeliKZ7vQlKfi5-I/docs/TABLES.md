---
published_at: 2026-08-12T00:00:00Z
summary: Oliver implements the GFM section 4.10 tables extension in the Markdown frontend; Textile has its own table syntax.
---

# Tables (GFM extension)

Oliver implements the GFM §4.10 tables extension in the **Markdown**
frontend (`oliver render --from markdown`). Textile has its own table
syntax (`|a|b|` rows with `|_. header|` cells, `table<mods>.` signatures,
colspan/rowspan, and header-alignment propagation — implemented, pinned
in docs/TEXTILE-PARITY.md §6); this extension is GFM-shaped only, per
recorded ambiguity 21.

The GFM spec
(<https://github.github.com/gfm/#tables-extension->, version 0.29-gfm) is
the normative source. The sections below pin the chosen behaviors where the
spec is silent or where its prose and examples disagree.

## 1. Shape

A table is a leaf block: a single **header row**, a **delimiter row**, and
zero or more **body rows**. It is recognized only when a fresh
single-line paragraph's line contains at least one unescaped `|` and the
*immediately following* line is a delimiter row with the same column
count. The table cannot interrupt an open paragraph: the header line must
be the first line of its paragraph, and a paragraph with prior content
(including a link reference definition line) never becomes a table.

```
| foo | bar |
| --- | --- |
| baz | bim |
```

## 2. Rows and cells

- Cells are separated by unescaped `|`; a leading and/or trailing pipe is
  optional and stripped escape-aware. `| a | b |`, `| a | b`, `a | b |`,
  and `a | b` are all two-column rows.
- Spaces and tabs between pipes and cell content are trimmed.
- `\|` is an escaped pipe: it is **content, never a separator** (so a cell
  can hold a literal pipe).
- A pipe-less line is still a row (one cell) while a table is open — the
  spec's `bar` example: `bar` after the rows is a row, `bar` after a blank
  line is a paragraph. Body rows are padded with empty cells when shorter
  than the header and truncated when longer.

## 3. The delimiter row

A delimiter row is required — without it, a lone `| A | B |` line stays a
paragraph. Each delimiter cell must match `:?-+:?` (hyphens with optional
leading/trailing colons) with the *chosen minimum*: **at least three
hyphens**, or **at least one hyphen when a colon is present**. The
colon-wrapped minimum reconciles the spec prose (which states no count)
with the issue contract ("3+ hyphens per column") and the spec's own
alignment example, whose first delimiter cell is the single-hyphen `:-:`:

```
| abc | defghi |
:-: | -----------:
bar | baz
```

Alignment: `---` unaligned, `:---` left, `---:` right, `:---:` center.
The alignment applies to every cell in the column (`<th>` and `<td>`).

Chosen behaviors where the spec is silent:

- **A pipe-less header line is never a table header** — `abc` followed by
  `| --- |` stays a paragraph, and a header whose only pipes are escaped
  is not a candidate either. (The spec recommends leading/trailing pipes
  "if there's otherwise parsing ambiguity"; the setext/table boundary is
  one such ambiguity, and `| a |` + `---` is a setext heading.)
- **The delimiter row must contain a pipe** — a bare `---` is a setext
  underline or thematic break, never a table delimiter.
- The header and delimiter column counts must match exactly, or "a table
  will not be recognized" and everything stays paragraph text (spec
  example: `| abc | def |` + `| --- |`).

## 4. Cell splitting

Cell splitting is escape-aware over the raw row bytes: a `\|` never
splits, and `\\|` splits (the escaped backslash first, then a real
separator). The splitter does not rewrite content — cell content handed
to the inline pass is the raw source span, and the inline pass's normal
backslash-escape handling renders `\|` as `|` in text, emphasis, and
link/URL contexts.

## 5. The one exception: code spans

Code-span content is opaque to the inline pass, so a `\|` inside a code
span keeps its backslash. To match the spec's §4.10 example exactly (``
`\|` `` renders `<code>|</code>`, and `**\|**` renders
`<strong>|</strong>`), the cell's inline pass post-processes code-span
content: the backslash directly before a pipe (an odd backslash run) is
dropped. Image `alt` strings flattened inside a cell receive the same
post-processing.

## 6. Termination and precedence

The table ends at the first blank line or the start of another
block-level structure (ATX heading, fenced code, thematic break, list
item that can interrupt, block quote, HTML block types 1–6). A pipe-less
non-blank line that is not a block start continues the table as a row.

- A table opening wins over §4.7 link-reference-definition extraction for
  a single-line paragraph (a def line containing a pipe, followed by a
  matching delimiter, becomes a table).
- Setext headings keep precedence: the header line must contain a pipe,
  so `| a |` + `---` is a setext heading, never a table.

## 7. The model and output

- `.table` (block; `data.table.alignment` per column) → rows → `.table_row`
  → cells → `.table_cell` (`data.table_cell.header` and `.alignment`,
  resolved at parse time) → inline content.
- HTML: `<table>` with `<thead>` (header row of `<th>`) and, when there is
  at least one body row, `<tbody>` of `<td>` rows. Aligned columns carry
  `align="left|center|right"`. `<tbody>` is omitted with no body rows.
- Cells are single-line: no block-level elements, no multi-line content.

## 8. Conformance status

Tables are an extension and are **not** part of the CommonMark 0.31.2
corpus: the 652/652 gate is unaffected (verified). The fixture wall
(`tests/fixtures/markdown/table-*.md`/`.html`) pins the normative GFM
examples byte-for-byte plus container, inline-content, and literal
coverage.
