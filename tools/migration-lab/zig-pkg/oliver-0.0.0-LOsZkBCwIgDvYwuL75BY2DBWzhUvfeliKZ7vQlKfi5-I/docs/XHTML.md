---
published_at: 2026-08-14T00:00:00Z
summary: The XHTML output profile: same normalized IR, same semantics, an XML-compatible serialization, with a fail-closed raw-HTML policy and a mechanical well-formedness gate.
---

# XHTML output profile

Oliver renders through **serializer profiles**. The default profile is HTML
(CommonMark-reference style); `.xhtml` is an explicit, deterministic,
XML-compatible serialization of the *same* normalized document (or Recipe)
with the *same* semantics. XHTML is an **output concern** — it never changes
Markdown, Textile, or Cooklang parsing semantics, and it is not a second
parser, a second document model, or a dialect-specific renderer.

```text
source dialect
    ↓
Oliver parser            ← unchanged for every profile
    ↓
normalized Document / Recipe IR
    ↓
serializer profile       ← html (default) | xhtml
    ↓
HTML or XHTML fragment
```

## Requesting XHTML

CLI (HTML remains the default; `render` with no `--to` means HTML):

```bash
oliver render --from markdown --to xhtml < document.md
oliver render --from textile  --to xhtml < document.textile
oliver render --from cooklang --to xhtml < recipe.cook
```

`--to html` is accepted and explicit; any other value fails with usage.
`--to` is rejected on the non-HTML Cooklang commands (`serialize`, `scale`,
`menu`) — those outputs are canonical Cooklang text, not HTML-family
rendering.

Library:

```zig
try oliver.html.render(allocator, &aw.writer, &result.document, .{ .profile = .xhtml });
try oliver.cooklang_html.render(allocator, &aw.writer, &cooked.recipe, .{ .profile = .xhtml });
```

`oliver.OutputProfile` (`html | xhtml`) is the shared selector. Existing
callers that request ordinary HTML are source-compatible: the default is
`.html` and output is byte-identical.

## The exact contract

The XHTML profile serializes Oliver's existing HTML semantics under
XML-compatible rules. It is a **fragment** serializer: `--to xhtml` emits an
XHTML-compatible fragment, never a document. No DOCTYPE is prepended and no
`<html>`, `<head>`, or `<body>` wrappers are fabricated — those are document
concerns that belong to a full-document API, not the fragment serializer.

- **Void elements** always use the XML empty-element form: `<br />`,
  `<hr />`, `<img ... />`. The `void_trailing_slash` HTML option is ignored
  under `.xhtml`; HTML mode keeps its existing policy unchanged.
- **Normal elements** retain explicit closing tags (`<p>…</p>`,
  `<strong>…</strong>`, `<table>…</table>`).
- **Attributes** are double-quoted, in the existing deterministic fixed
  order, with the existing XML-predefined escaping (`&` → `&amp;`, `<` →
  `&lt;`, `>` → `&gt;`, `"` → `&quot;`). Oliver does not emit HTML boolean
  attributes, so there is no minimization to expand.
- **Escaping** reuses the renderer's one escaping policy: the XML
  predefined entities plus NUL → U+FFFD, applied to text, code spans, code
  blocks, URLs (`href`/`src` percent-encoding is unchanged), titles, alt
  text, and generated attributes. Unicode passes through as codepoints —
  no named-entity tables, no lossy rewriting.
- **Whitespace and newlines** follow the existing policy exactly: `\n`
  only, one trailing `\n` per block, deterministic everywhere.

Because the default HTML serializer already emits XML-style voids and the
XML predefined escapes, most documents render **byte-identically** in both
profiles. That is intentional and is asserted in the test suite: the XHTML
profile owns only the deltas it must — the guaranteed XML void form, and the
fail-closed raw-content policy below.

## Raw HTML policy

Oliver's HTML profile deliberately passes raw HTML source through verbatim
(Markdown raw-HTML leaves and HTML blocks; Textile `pre.` blocks and
`notextile.`). That is acceptable for HTML. It is **not** safe to claim as
XHTML: arbitrary raw HTML can be non-well-formed XML.

The XHTML profile is **fail-closed**. If the normalized document contains
raw content Oliver cannot guarantee is XML-well-formed — `.raw_html`,
`.html_block`, or a Textile `pre.` (verbatim `<pre>`) block — XHTML
rendering fails with the typed error `error.RawHtmlNotXmlWellFormed` and
the CLI prints an actionable hint. Oliver never reparses, repairs, or
silently rewrites raw HTML, and never escapes it into text; malformed raw
HTML is simply not claimed to be XHTML.

```bash
$ echo '**hi** <b>raw</b>' | oliver render --from markdown --to xhtml
oliver: render failed: RawHtmlNotXmlWellFormed
oliver: --to xhtml rejects raw HTML that cannot be guaranteed well-formed XML
(docs/XHTML.md section 5): remove or escape the raw HTML, or render with --to html.
```

Escaped code (fenced/indented blocks, code spans) is *not* raw HTML and
renders normally — the content is escaped literal text.

## Semantics are shared

Changing `--to html` to `--to xhtml` must not change heading structure,
list tightness, links, emphasis, tables, block quotes, code, Textile
attributes, or Cooklang recipe semantics — only the serialization bytes the
profile owns. The paired fixtures in `tests/xhtml_test.zig` document this:
most pairs are byte-identical, and the ones that differ differ only in the
declared serialization delta. The Cooklang line break is the one genuine
byte delta in the Recipe renderer (`<br>` → `<br />`).

## Well-formedness gate

`tests/xhtml_wellformed.zig` is a small, deterministic, test-only XML
well-formedness scanner used as **machine evidence** that representative
XHTML output is valid XML. It checks balanced, name-matched elements;
quoted, unique attributes; the five predefined entities and numeric
references; comments, CDATA, and processing instructions; and character
validity. Representative Markdown, Textile, and Cooklang XHTML fragments
are wrapped in a minimal namespace-aware test wrapper and validated:

```xml
<html xmlns="http://www.w3.org/1999/xhtml">
  <body>
    ...Oliver fragment...
  </body>
</html>
```

The wrapper belongs to the **test only** — Oliver fragment output never
acquires fake document wrappers. The checker is deliberately not an XML
parser authority: it validates output; it never participates in parsing
semantics. (Zig 0.16 ships no `std.xml`; the checker is hermetic and
dependency-free.)

## Determinism

XHTML output obeys Oliver's deterministic-output philosophy: same input
bytes, dialect, parser options, profile, and version produce byte-identical
output. Repeated-render comparisons are part of the suite.

## Dialect coverage

- **Markdown** — the CommonMark 0.31.2 gate remains fully green and is
  HTML-reference behavior; XHTML tests layer above parser conformance.
- **Textile** — the same normalized document; Textile structures and
  attributes (phrase attrs, tables, spans) are covered.
- **Cooklang** — Recipe IR renders through the same profile concept in
  `src/cooklang_html.zig` (ingredients, cookware, timers, quantities,
  metadata/containers); Recipe IR is never reparsed through the Document IR.

## Not claimed

No XHTML 1.0 Strict/Transitional DTD validation, no XHTML 1.1, no HTML 4,
no browser-compatibility shims. Those could become later compatibility
profiles if evidence demands them. The guarantee is narrow and precise:
Oliver's generated fragments are well-formed XML under the rules above, and
Oliver will not claim otherwise.
