# Bounded Textile-to-Markdown compatibility adapter

**Status:** normative, additive input compatibility slice
**CLI selector:** `--textile`
**Adapter identity:** `boris-textile-adapter-v1`

This compatibility slice is a small tribute to Textile creator Dean Allen. It
is deliberately an adapter into Boris, not a Textile implementation and not a
second site compiler.

The syntax names and source examples below are grounded in the official
[Textile language documentation](https://textile-lang.com/doc/), especially
its references for [headings](https://textile-lang.com/doc/headings),
[block quotations](https://textile-lang.com/doc/block-quotations),
[lists](https://textile-lang.com/doc/bulleted-unordered-lists),
[phrase modifiers](https://textile-lang.com/doc/strong-and-bold-text), and
[links](https://textile-lang.com/doc/links). Boris intentionally accepts only
the closed subset in this contract.

## Activation and discovery

- `--textile` is an input-format modifier. It combines with the existing HTML
  default, IR, RAG, Context Bundle, `check`, `impact`, incremental, watch, jobs,
  and multi-target output selectors.
- Without `--textile`, page discovery accepts lowercase `.md` and `.mdx` only.
- With `--textile`, page discovery accepts lowercase `.textile` only.
- Extensions are case-sensitive. `.TEXTILE` is not a page.
- A page tree containing both a Markdown page (`.md` / `.mdx`) and a Textile
  page (`.textile`) fails with `ETEXTILE`; Boris never guesses a dialect per
  page. The reserved content-root `includes/` fragment tree is not a page tree
  and remains excluded from discovery.
- A Textile-only tree invoked without `--textile`, or a Markdown-only tree
  invoked with `--textile`, also fails with `ETEXTILE` and a mode-selection
  remediation. Other non-page files retain the scanner's existing ignore rule.

## Pipeline position and invariants

```text
scan selected extension
  -> parse the existing Boris frontmatter from original source bytes
  -> convert only the body to Markdown in memory
  -> existing component/dependency validation
  -> existing Apex / IR / RAG / Context / graph pipeline
```

The frontmatter grammar is unchanged and remains normative under
[frontmatter.md](frontmatter.md). In particular, `parent` is the only parent
key and Trunk/Satellite validation is unchanged. The adapter never sees or
rewrites frontmatter.

`bodyOffset` remains a byte offset into the original `.textile` source. Entity
ids and output paths are derived by stripping `.textile` exactly as `.md` and
`.mdx` are stripped. No IR schema, RAG schema, Context schema, compiler id, or
product version changes for this additive mode.

## Supported block subset

Blocks are separated by one or more blank physical lines. LF and CRLF input
are accepted; adapted Markdown uses LF. Blank-line count is preserved.

| Textile input | Adapted Markdown | Bound |
|---|---|---|
| `h1. Text` through `h6. Text` | `# Text` through `###### Text` | Heading is one non-empty physical line and occupies its own block. Exactly one ASCII space follows `.`. |
| Plain non-blank lines | same paragraph text after safe inline conversion | Consecutive lines form one paragraph. |
| `p. Text` | `Text` | Optional explicit paragraph signature on the first line of a paragraph block only. |
| `bq. Text` | `> Text` | One non-empty paragraph; continuation lines in the same block are quoted. Citations and `bq..` are unsupported. |
| `* Item` | `- Item` | Flat unordered list; every line in the block is a non-empty `* ` item. |
| `# Item` | `1. Item`, `2. Item`, … | Flat ordered list; every line in the block is a non-empty `# ` item and output numbering is deterministic from 1. |

Nested or mixed list markers are outside this slice. Because Apex Unified mode
intentionally merges adjacent list blocks with different marker types, such
adjacent unordered/ordered blocks fail with `ETEXTILE`; an ordinary paragraph
between them makes each block unambiguous.

## Supported inline subset

| Textile input | Adapted Markdown / safe HTML |
|---|---|
| `*strong*` | `**strong**` |
| `_emphasis_` | `*emphasis*` |
| `-deleted-` | `~~deleted~~` |
| `+inserted+` | `<ins>inserted</ins>` |
| `@code@` | Markdown code span |
| `"label":destination` | `[label](destination)` |

Phrase modifiers are same-line, non-empty, and non-nesting in this slice. An
opening delimiter is recognized only at the start of inline text or after
ASCII whitespace or opening punctuation, and a closing delimiter must be
followed by end-of-line, ASCII whitespace, or closing punctuation. A
recognized opener without a valid closer fails with `ETEXTILE`; it is not
silently emitted as punctuation.

Inline code may not contain a line break or backtick. Link labels are plain
text: Textile link titles, aliases, images, classes, and nested phrase
modifiers are unsupported.

Safe link destinations are non-empty UTF-8 without whitespace, controls,
backslashes, quotes, angle brackets, or literal parentheses, and must be one
of:

- `http://` or `https://`;
- `mailto:`;
- a root-relative `/…`, dot-relative `./…` or `../…`, or fragment `#…` path.

Other schemes, including `javascript:`, fail with `ETEXTILE`.

## Escaping and generated HTML

The adapter escapes literal Markdown punctuation so a Textile paragraph cannot
smuggle an unrelated Markdown construct into Apex. Literal `&`, `<`, and `>`
become HTML entities before Apex. Raw HTML is never passed through.

The only generated raw HTML is the fixed `<ins>…</ins>` wrapper because the
Markdown path has no insertion equivalent. Its content is entity-escaped and
cannot add attributes or tags. Delete uses Apex's existing `~~…~~` Markdown
path. Links use Markdown rather than generated anchors.

## Unsupported syntax

The following recognized forms fail with `ETEXTILE` and a source location:

- block or phrase attributes, class/id syntax, language modifiers, alignment,
  indentation, and arbitrary CSS;
- tables and table modifiers (including `table.` declarations and attributed
  declaration variants), footnotes, endnotes, and definition lists;
- extended blocks (`..`), block code / preformatted blocks, comments, and
  `notextile` blocks;
- nested or mixed lists and list attributes;
- images, link aliases, link titles/classes, raw HTML, and all phrase modifiers
  outside the table above;
- Boris `{{include …}}` macros, `[[…]]` wiki links, `<Aside>`, and other
  component tags. These existing Markdown authoring extensions are not
  reinterpreted as Textile.

Malformed forms inside the supported subset also fail loud: empty headings,
quotes or list items; a heading sharing a block with following text; unmatched
phrase delimiters; incomplete links; and unsafe link destinations.

## Diagnostics

`ETEXTILE` is a content error (exit `1`). It covers input-mode extension
mismatch, unsupported recognized Textile syntax, malformed supported syntax,
and unsafe link destinations. Diagnostics use the original `.textile` source
path and 1-based line / byte column when a page location is available.

Frontmatter and UTF-8 errors retain their existing `EFRONTMATTER`,
`EINVALIDPATH`, and `EINVALIDUTF8` categories because frontmatter parsing runs
before body adaptation.

## Output and cache behavior

- HTML: adapted Markdown follows the existing include/wiki/component stages
  (which are inert for valid Textile input), then Apex and the normal layout
  splice. There is no direct Textile-to-HTML renderer.
- IR: graph and artifact shape are unchanged. `sourcePath` ends in `.textile`
  and `bodyOffset` refers to original source bytes.
- RAG: content-page bodies use adapted Markdown and the existing H1 ownership
  and Aside-export rules (valid Textile cannot contain Asides).
- Context Bundle: validation uses the adapted body, while the provenance fence
  and `source_sha256` continue to describe the exact original `.textile` source
  bytes. This preserves the Context Bundle's source-provenance contract.
- Incremental HTML: the fingerprint includes exact original source bytes plus
  the fixed adapter identity above. A source change or future intentional
  adapter-identity change invalidates the page; Markdown fingerprints remain
  unchanged.

## Fixtures and acceptance

Normative fixtures live under `docs/contracts/fixtures/textile-compatibility/`.

1. Adapter output for each valid page matches `expected/adapted/*.md` exactly.
2. `boris --textile --input …` preserves the fixture's parent graph in IR.
3. HTML contains the expected heading, paragraph, quote, lists, inline
   semantics, safe link, and escaped literal angle/ampersand text.
4. RAG content pages contain adapted Markdown, not raw Textile signatures.
5. Unsupported and malformed fixtures fail with `ETEXTILE` and publish no
   graph-dependent output.
6. Mixed Markdown/Textile page trees fail with `ETEXTILE` in either input mode.
7. Sequential, parallel, and repeated parallel HTML builds are byte-identical
   for the valid fixture.
