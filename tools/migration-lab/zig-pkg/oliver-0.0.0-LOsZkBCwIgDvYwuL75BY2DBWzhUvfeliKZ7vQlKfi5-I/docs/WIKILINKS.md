---
published_at: 2026-08-16T00:00:00Z
summary: The opt-in modular wikilinks extension ([[target]] / [[target|label]]) in the Markdown frontend: shape, precedence, fallbacks, and the resolver policy.
---

# Wikilinks (extension)

**Status:** implemented — opt-in Markdown dialect extension (issue #64,
milestone v0.5, "The Green Pastures Release"; ledger card E1).  \
**Modules:** `src/markdown.zig` (parse), `src/document.zig` (model),
`src/html.zig` (render)  \
**Options:** `markdown.Options.wikilinks: bool = false` (parse);
`html.RenderOptions.wikilink_resolver` (render, optional fn pointer +
opaque context) and `wikilink_resolver_ctx`

Wikilinks are not part of CommonMark 0.31.2, GFM, or Textile. They are a
consumer-driven extension — like footnotes, definition lists, heading
attributes, and strikethrough (docs/MARKDOWN-EXTENSIONS.md) — modeled on
Obsidian's de-facto syntax, which is user-facing documentation and
clean-room allowed; the provenance record is docs/CLEANROOM.md session
24. The extension is **off by default**, so
default-option output stays byte-exact CommonMark and the 652/652 gate
is untouched.

## 1. Shape

- `[[Page Name]]` — a wikilink with target `Page Name` and no label.
- `[[Page Name|Custom Label]]` — target `Page Name`, label `Custom Label`.
- The target is the bytes between `[[` and the first unescaped `|` or the
  closing `]]`; the label is the bytes after the first `|` up to `]]`.
- Leading and trailing whitespace of the target and label are trimmed
  (pinned); internal whitespace is preserved verbatim (`[[Page Name]]`
  keeps the space).
- An empty target (`[[]]`), an empty label (`[[x|]]`), a label-side-only
  form (`[[|x]]`), and a whitespace-only target (`[[ ]]`) are malformed →
  literal. A label containing a `|` (`[[a|b|c]]`) is malformed → literal.

## 2. Recognition and precedence

- `[[` is discovered in the inline scan **ahead of link/image bracket
  matching**, in the same discovery family as autolinks. A `[[` run takes
  priority over treating its first `[` as a link opener.
- **Atomic fallback:** once `[[` is seen at a bracket position, the
  construct either completes as a wikilink or the `[[` is emitted as
  literal text; the bracket machinery never re-visits the consumed `[[`.
  Recorded divergence when the option is on: `[[foo]](/url)` closes at
  the first `]]` as the wikilink `[[foo]]` and leaves `(/url)` as literal
  text (today, extension off, `[foo](/url)` is a link). The fallback
  fires only when no closing `]]` exists before the end of the inline
  scope. Pinned by the `wikilink-precedence` fixture.
- The closing `]]` is the first *unescaped* `]]`; a backslash-escaped `]`
  inside the construct does not close it. A target may not contain `[[`
  (`[[a [[b]]` is malformed → literal, pinned).
- The closer is greedy: `[[a]]]` is the wikilink `[[a]]` followed by a
  literal `]` (pinned).
- Wikilinks are **opaque** inside: code spans, code blocks (fenced and
  indented), autolinks, link destinations and titles, image src/alt/title,
  raw HTML and inline HTML, link display text, and image descriptions (a
  wikilink in `[text]` or `![alt]` stays literal — this keeps alt
  flattening stable and prevents nested anchors).
- Target and label are **plain text**: never re-scanned for emphasis,
  links, or other syntax; escaped at render like ordinary text.
- Backslash escapes apply: `\[[` renders a literal `[` and never starts a
  wikilink.

## 3. Fallbacks (all literal, each pinned by a fixture)

- `[[` with no closing `]]` before the end of the containing inline scope.
- `[[]]`, `[[x|]]`, `[[|x]]`, `[[ ]]`, `[[a|b|c]]`, `[[a [[b]]`.
- A `]]` straddling... (none — the closer is a contiguous `]]`).
- Greedy close `[[a]]]` (trailing `]` is ordinary text, above).

## 4. Model

A new inline leaf tag `.wikilink`:

```zig
data.wikilink = .{
    .target: []const u8,
    .label: ?[]const u8, // null when absent
}
```

- The node span covers the whole `[[…]]` construct (like `.code_span`).
- `target` is the trimmed source bytes; `label` is the trimmed label when
  present. Both are source slices: trimming narrows the span, so no copy
  is needed.
- A wikilink node never merges with adjacent text nodes (model
  invariant 11).

## 5. Resolution (renderer policy)

Parse produces the typed node; resolution is a **renderer policy**,
mirroring the existing record that href percent-encoding is a renderer
policy (docs/ARCHITECTURE.md).

- **Default resolver** (no hook supplied): `href` = the target through the
  standard link href percent-encoding policy (so `[[Page Name]]` →
  `href="Page%20Name"`); `text` = `label orelse target`.
- **`html.RenderOptions.wikilink_resolver`**: an optional comptime-known
  function plus an opaque context value (the freestanding core has no
  closures), with the shape

  ```zig
  const ResolvedWikilink = struct { href: []const u8, text: []const u8 };
  // fn (target: []const u8, label: ?[]const u8, ctx: ?*const anyopaque) ResolvedWikilink
  ```

  The resolver returns memory that outlives the render call (the caller's
  arena or static data); the renderer never frees it.
- **Determinism:** the default and any resolver are pure functions of
  (target, label, ctx) — no hidden state, matching the no-global-state
  design value.
- Both the default and a supplied resolver must pass the XHTML
  well-formedness gate (tests/xhtml_wellformed.zig).

## 6. Rendering

- `<a href="{href}">{text}</a>` — href through the href escaping and
  percent-encoding policy; text escaped like plain text.
- Both output profiles (`html`/`xhtml`) render identical structure: no
  void elements, no valueless attributes.

## 7. Interaction with the other extensions

- `smartypants`: the wikilink payloads are plain text and sit inside the
  exemption set (docs/SMARTY.md) — the label is not re-scanned.
- `callouts`: a `[[x]]` inside a callout body is a normal inline.
- `front matter`: never contains wikilinks (stripped before the body
  parses).
- **GFM tables:** an unescaped `|` inside a wikilink in a table cell is a
  cell separator per GFM §4.10 row splitting, so `| [[cell|Label]] |`
  splits the row into two cells. A pipe label inside a table cell needs
  `\|` — and since wikilink content is never re-scanned, the escaped
  pipe stays raw in the target. Pinned by the `wikilink-basic` fixture
  (which avoids the ambiguous shape).

## 8. Acceptance and fixtures (shipped)

- `[[Page Name]]` → `<p><a href="Page%20Name">Page Name</a></p>` under the
  default resolver — byte-pinned by `tests/fixtures/markdown/wikilink-basic`.
- `[[Page Name|Custom]]` → `<a href="Page%20Name">Custom</a>`.
- A consumer resolver changes href/text deterministically (unit tests in
  `src/markdown.zig`, incl. the opaque-context pass-through; the XHTML
  well-formedness gate in `tests/xhtml_test.zig` covers both resolver
  paths).
- Fixture wall: `wikilink-basic` (prose, headings, lists, table cells,
  trimming, labels), `wikilink-literal` (the §3 battery + the greedy
  closer `[[a]]]`), `wikilink-precedence` (`[[x]]` vs the `[x]` def,
  `[[foo]](/url)`, link-text demotion, code-span/autolink opacity),
  `wikilink-escapes` (`\[[x]]`, `[[a\]b]]`). Cross-extension
  compositions are pinned by `cross-callout-title` (a `[[x]]` inside a
  callout title and body) and `cross-smartypants-scopes` (a heading
  containing a wikilink slugs on the label: `# See [[Page Name]] now` →
  `id="see-page-name-now"`).
- Unit tests: node structure/spans, disabled behavior, malformed battery,
  greedy closer, link-text demotion, default + consumer resolver
  rendering, and a 10,000-wikilink determinism storm.
- Off by default: `[[x]]` renders exactly as today (literal brackets) —
  652/652 + full suite green (re-verified at integration).

## 9. Conformance status

Extension, off by default: the CommonMark 0.31.2 corpus is untouched
(re-verified at integration). The fixture wall lives at
`tests/fixtures/markdown/wikilink-*`.
