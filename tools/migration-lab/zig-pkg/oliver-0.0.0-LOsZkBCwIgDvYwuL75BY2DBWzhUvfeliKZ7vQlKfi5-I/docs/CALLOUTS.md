---
published_at: 2026-08-16T00:00:00Z
summary: Contract for the opt-in Obsidian-style callout extension (> [!note]) in the Markdown frontend — implemented (issue #65).
---

# Callouts (extension) — contract

**Status:** implemented — shipped via issue #65 (milestone v0.6, "The
Obsidian Run"); the provenance record is in docs/CLEANROOM.md session
26.  \
**Modules:** `src/markdown.zig` (parse), `src/document.zig` (model),
`src/html.zig` (render)  \
**Options:** `markdown.Options.callouts: bool = false`

Callouts are not part of CommonMark 0.31.2, GFM, or Textile. They are a
consumer-driven extension modeled on Obsidian's published callout syntax
(`> [!note] Title`), which is user-facing documentation and clean-room
allowed; the provenance record is added to docs/CLEANROOM.md when the
feature lands. With the extension **off** (default), `> [!note]` is an
ordinary §5.1 blockquote whose first paragraph starts with the literal
text `[!note]` — the corpus is untouched.

## 1. Shape

```markdown
> [!note] Title here
> Body line.
> Another body line.
```

- A **leading `[!type]`** immediately after the blockquote marker on the
  blockquote's **first content line** turns the blockquote into a
  callout.
- The **type** is a non-empty run of ASCII letters, digits, and `-`,
  case-insensitive (`[!NOTE]`, `[!Note]`). `[!]` (empty) and `[!two
  words]` (space) are not types → literal.
- After the `]`, a space or tab (or end of line) is required; `[!note]x`
  with no separator is not a callout → literal.
- The **title** is the inline-parsed content of the remainder of the
  first line after the separator (`Title here`); a line that is only
  whitespace after `]` has no title.
- The **body** is the rest of the blockquote: subsequent `>` lines, lazy
  continuation, nested containers — exactly the §5.1 container-stack
  extent. A truly blank line ends the callout (it ends the blockquote);
  no new blank-line semantics are introduced.
- **Lazy-continuation boundary (pinned by `cross-callout-edges`):**
  lazy continuation continues an *open* body paragraph only. A line
  immediately after the title line — before any body paragraph is open
  — is not part of the callout: it becomes a sibling block. Once a body
  paragraph exists (`> Body one.`), a non-marker line lazily continues
  it inside the callout, exactly as §5.1 does for ordinary blockquotes.

## 2. Recognition

- Recognition happens only on the **first content line** of a blockquote,
  after the §5.1 marker consumption (the `>` and its one following
  column, which may be the space in `> [!note]` or the `[` itself in
  `>[!note]` — both forms work).
- The remaining line content must then start with `[!` — no leading
  whitespace between the marker and the `[`.
- `[!note]` on any non-first line of a blockquote is ordinary text.
- A nested blockquote whose own first line is `[!type]` is a nested
  callout (works through the container stack; callout-in-callout).
- The `[!type]` marker bytes are consumed — never rendered as text.

## 3. Unknown types

- An unknown type is still a callout and renders the default
  (note-styled) box. The normalized (lowercased) type is preserved in the
  class `callout-<type>` (Obsidian's behavior), and the model keeps the
  source type bytes, so consumers can style or detect any type.

## 4. Model

The `.block_quote` container gains an optional callout payload (the
chosen approach: reusing the §5.1 container stack keeps nesting,
laziness, list/quote composition, and nested callouts free):

```zig
data.block_quote = .{
    .callout_type: ?[]const u8 = null,  // normalized lowercase type
    .callout_title: ?[]const u8 = null, // raw title bytes, trimmed
    .callout_title_nodes: []*Node = &.{}, // title, inline-parsed
}
```

- `callout_type`/`callout_title` are null for ordinary blockquotes —
  Markdown and Textile output is byte-identical.
- `callout_title` is a borrowed source slice (trimmed); the parsed form
  lives in `callout_title_nodes` (arena-owned), so emphasis/wikilinks
  work in titles. Empty for ordinary blockquotes and titleless callouts.
- A dedicated `.callout` tag was considered and rejected in this
  contract: the container machinery is the same, and the payload keeps
  the shared model convergent.

## 5. Rendering

When the payload is set:

```html
<div class="callout callout-note">
<div class="callout-title">Title here</div>
<p>Body line.</p>
</div>
```

- The wrapper becomes `<div class="callout callout-<type>">` — a
  deliberate element change from `<blockquote>` (the Obsidian/admonition
  convention); `<div>` is a valid XHTML container.
- The title, when present, renders as `<div class="callout-title">` as
  the first child; when absent, no title div is emitted.
- The body children render exactly as blockquote children do today
  (paragraphs, lists, code, nested containers).
- When the payload is absent: byte-identical `<blockquote>…</blockquote>`.
- Both output profiles are identical in structure; no valueless
  attributes (the XHTML well-formedness gate must pass).

## 6. Fallbacks (all literal, pinned by fixtures)

- The extension is off (default): `> [!note]` is an ordinary blockquote,
  `[!note]` literal text in its first paragraph.
- `[!note]` mid-line (`> text [!note]`), on a non-first line, or without
  a separator after `]` (`[!note]x`).
- Malformed types: `[!]` (empty), `[!two words]` (space in the type),
  `[!note!]` (punctuation in the type), `[!note` (no `]`) — all pinned
  literal by `cross-callout-edges`.
- `[!note]` not at the start of the line content (leading whitespace
  after the marker).

## 7. Interaction with the other extensions

- `wikilinks`: a `[[x]]` in the title or body is a normal inline (the
  title is inline-parsed in the same inline pass).
- `smartypants`: applies to title and body plain text like any inline
  scope.
- `front matter`: stripped before the body parses; never inside a
  callout.

## 8. Acceptance and fixtures

- `> [!note] Title\n> body` →
  `<div class="callout callout-note">\n<div class="callout-title">Title</div>\n<p>body</p>\n</div>\n`
  — byte-pinned.
- Case-insensitive types (`[!TIP]` → `callout-tip`); unknown types
  (`[!custom-unknown]`-style) → `callout-<type>` box (the type name is
  preserved in the class, Obsidian's behavior); titleless callouts;
  multi-paragraph bodies; lazy continuation (with the §1 boundary);
  nested callouts; lists, links, and emphasis inside bodies; both
  marker-adjacency forms (`> [!note]` and `>[!note]`, pinned by
  `cross-callout-title`).
- Cross-extension: a `[[x]]` wikilink in the title or body is a normal
  inline, and smartypants applies to title/body plain text around it
  (pinned by `cross-callout-title`: `> [!note] See [[Page Name]] and
  "quoted" -- text` renders the resolved link, curly quotes, and em
  dash in the title).
- The §6 literal battery — `[!note]x`, `[!]`, `[!no close`, a mid-line
  `[!note]` (pinned by `callout-literal`), and `[!two words]`/`[!note!]`
  (pinned by `cross-callout-edges`, with the lazy-continuation boundary
  in both directions).
- XHTML well-formedness gate passes for every fixture.
- Off by default: 652/652 + full suite green.

## 9. Conformance status

Extension, off by default: the CommonMark 0.31.2 corpus is untouched
(re-verified at integration: 652/652 with the `--gate` harness).
Fixture wall: `callout-basic` (title + body + lazy continuation),
`callout-types` (case-insensitivity, titleless, unknown types),
`callout-body` (inline title, links, lists, nested callouts, multi-block
bodies), `callout-literal` (§6 battery + mid-line rule), and the
cross-extension `cross-callout-title` (wikilinks + smartypants in
titles, the no-space `>[!note]` form) and `cross-callout-edges`
(`[!two words]`/`[!note!]`, the §1 lazy-continuation boundary). The
XHTML well-formedness gate covers the div wrapper under both profiles.
