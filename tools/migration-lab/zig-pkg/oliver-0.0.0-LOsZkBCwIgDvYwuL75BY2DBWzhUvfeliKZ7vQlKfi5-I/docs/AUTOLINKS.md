---
published_at: 2026-08-12T00:00:00Z
summary: Contract record for the autolinks slice of Oliver's Markdown frontend (URI and email autolinks), implemented and tested.
---

# Oliver Inline Parsing: Autolinks (§6.8)

**Status: implemented (Markdown).** This document began as the design
note (written before any code) and is now the contract record for the
autolinks slice of Oliver's Markdown frontend: URI
autolinks (`<scheme:...>`) and email autolinks (`<user@host>`). It is
derived entirely from the CommonMark specification (0.31.2) and Oliver's
own docs, and it is written *before* implementation, like
docs/INLINE-PARSING.md (emphasis), docs/IMAGES-PARSING.md (images), and
docs/REFERENCE-IMAGES.md (reference-style images).

Clean-room note: only specification text (the CommonMark 0.31.2
`spec.txt` and numbered HTML, including the HTML5 email regex it cites)
and Oliver's own docs were consulted. No parser implementation source was
read, searched, or imitated.

## 1. What the spec says

From §6.8, verbatim in substance:

> [Autolinks] are absolute URIs and email addresses inside `<` and `>`.
> They are parsed as links, with the URL or email address as the link
> label.

- **URI autolink:** `<` + [absolute URI] + `>`. For these purposes an
  absolute URI is a [scheme] followed by `:` followed by zero or more
  characters other than ASCII control characters, space, `<`, and `>`.
  (Characters that would violate this must be percent-encoded — which is
  why `%` is preserved and `\`/`[` inside an autolink stay literal and get
  percent-encoded at render time.)
- **Scheme:** any sequence of 2–32 characters beginning with an ASCII
  letter and followed by ASCII letters, digits, `+`, `.`, or `-`. So
  `<m:abc>` is not an autolink (1-char scheme), while `<a+b+c:d>`,
  `<made-up-scheme://foo,bar>`, `<localhost:5001/foo>`, and
  `<MAILTO:FOO@BAR.BAZ>` are (schemes need not be registered URIs).
- **Email autolink:** `<` + [email address] + `>`. An email address
  matches the non-normative regex from the HTML5 spec:
  `/^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/`
  The link's label is the email address; the URL is `mailto:` + the
  address.
- **Backslash escapes do not work inside autolinks** (both kinds):
  `<https://example.com/\[\>` is a URI autolink whose literal content
  includes the backslashes (they are percent-encoded in the href), and
  `<foo\+@bar.example.com>` is *not* an email autolink (a `\` is not a
  legal local-part character), rendered as literal escaped text.
- **Precedence:** "Code spans, HTML tags, and autolinks have the same
  precedence" (§6.2) and "Backtick code spans, autolinks, and raw HTML
  tags bind more tightly than the brackets in link text" (§6.3). The
  first-come-wins rule between code spans and autolinks is pinned by the
  example pair `` `<https://foo.bar.`baz>` `` (code span wins: it starts
  first) vs `<https://foo.bar.`baz>` (autolink wins: it starts first,
  the backtick is ordinary URI content).

## 2. Placement on the seam

Autolinks are a **scan-time recognizer**, like code spans — not a
discovery-pass restructure like links. The scan (`scanLine`) already
walks each line's raw span left to right, skipping code-span ranges
(discovered ahead by `discoverCodeSpans`). Adding a `<` branch:

- The `<` branch fires only when the scan reaches it, so the
  first-come-wins rule with code spans falls out of the existing
  left-to-right walk: if a backtick run starts before the `<`, the
  code-span skip consumes it; if the `<` starts first, the autolink scan
  consumes the whole `<...>` (advancing past any backtick runs inside).
  This reproduces the spec's example pair with no new pass ordering.
- Autolinks cannot contain line endings (they are excluded as control
  characters), so per-line scanning is complete; no cross-line machinery
  is needed.
- Link destinations are scanned from raw bytes by `tryParseLink` *after*
  the scan; an angle destination like `[x](<https://y>)` is consumed by
  link discovery even though the scan also recognizes the autolink (the
  `(...)` consumption loop drops the autolink item). No special-casing
  needed.
- **Escaped `<`** (`\<`) is literal text, exactly like escaped `[`/`]`:
  the branch requires `!isEscaped`.

### The item and its shape

A matched autolink becomes a new leaf `InlineItem.autolink`
`{ span, content, is_email }` (`span` covers `<...>`, `content` the bytes
between the angle brackets, `is_email` selects the `mailto:` prefix).
Like `code_span`, it is opaque to the delimiter stack and to link
discovery.

**Order of attempts:** URI first, then email. The URI test is: after the
`<`, a 2–32-char scheme (ASCII letter, then letters/digits/`+`/`.`/`-`),
then `:`, then scan to the first `>` allowing any byte except ASCII
control, space, `<`, `>`. The email test is: the bytes between `<` and
the first `>` fully match the HTML5 regex (local part, `@`, domain with
the 0–61-hyphen label rule). If neither matches, the `<` is literal
text.

## 3. Model and renderer

`.autolink` joins the leaf inlines (`text`, `code_span`, `image`,
breaks): **no children**, `data.autolink = { href, label }`, both
arena-owned copies. `href` is the raw content (URI) or `"mailto:" +
content` (email); `label` is the raw content. **Escapes are inert**: the
content is copied verbatim, never passed through `resolveEscapes`
(that is the whole difference from `data.link`, whose href is
escape-resolved).

The renderer emits `<a href="...">label</a>`: `href` through the
existing `writeEscapedHref` (percent-encode + HTML-escape — the same
policy as link hrefs, which is exactly what the spec's expected outputs
show: `\`→`%5C`, `[`→`%5B`, backtick→`%60`, `&`→`&amp;`), and `label`
through `writeEscaped` like text. Attribute order is fixed: `href` only
(autolinks have no title).

`flattenAlt` (image descriptions) gains an `.autolink` case: the plain
string content is the raw content bytes (per §6.7 "only the plain string
content").

## 4. Chosen behaviors and recorded divergences

1. **Percent-encoding of non-ASCII** follows the existing href policy
   (each byte `%XX`), a renderer choice the spec explicitly leaves open —
   unchanged from links.
2. **The HTML5 email regex is implemented mechanically** (local-part
   character set, `@`, and the domain-label shape with the 61-hyphen
   bound), not approximated.
3. **Raw HTML is handled by the neighboring recognizer**: a whole-paragraph
   `discoverHtmlTags` pass claims valid tags before this `<` recognizer runs.
   Such tags are opaque to link brackets and delimiters; this document's
   autolink rules apply only when the raw-HTML scan fails. The
   `[foo <bar attr="](baz)">` shape therefore keeps the tag's brackets and
   parentheses opaque rather than accidentally forming a link.
4. **Entities are decoded inside autolinks.** The spec §2.5 recognizes entity and character references anywhere except code blocks, code spans, and HTML tags, so `&amp;` inside an autolink decodes in both the href and the label (cmark parity); the escaped `&` then percent-encodes to `%26` in the href and re-escapes to `&amp;` in the label. Structural characters from entities still cannot substitute for syntax — `&#42;` never opens emphasis or a list item, because parsing happens on source bytes.
5. **`<`/`>` inside an autolink's content** are impossible by
   construction (the scan stops at the first `>` and rejects `<`), so no
   escaping of them is needed.

## 5. Verification and test plan

1. Verify the §6.8 spec examples (autolinks section) byte-for-byte via
   the spec-conformance harness (`zig build spec-conformance -- spec.txt
   --section Autolinks`), which the spec scorecard milestone added — the
   current baseline is 8/19 (the negative examples). All 19 should pass.
2. Fixtures: `autolink-*.md`/`.html` — URI (http/https/irc/uppercase
   scheme/unregistered schemes), email, escaped-content URI (backslashes
   percent-encoded), space-rejected, empty, one-char scheme, escaped
   bang-in-email rejected, code-span-vs-autolink precedence pair,
   autolink inside link text, autolink inside an image description,
   `<` inside code span, and literal non-matches.
3. Unit tests: URI/email recognition and span boundaries, the scheme
   rule (2–32 chars, allowed symbols), the HTML5 email regex edge cases
   (local-part symbols, domain label bounds, hyphen rules), precedence
   with code spans and link brackets, escapes-inert, model payloads
   (href/label), and `flattenAlt` through an autolink.
4. Adversarial smoke: long `<`-runs without `>`, deep `scheme:` runs,
   email-regex-shaped bombs (many `@`/`.` separators), autolinks mixed
   with the existing bracket/delimiter workload — no quadratic or
   recursion surface (the scan is per-line and single-pass).
5. Quality gate: `zig fmt --check`, `zig build`, `zig build test` green;
   the whole pre-existing suite must pass unchanged, and the spec
   scorecard's Autolinks row must go 8/19 → 19/19.

**Completed (session 8):** all five items above landed. Autolinks 8/19 →
19/19 byte-for-byte; 25 `autolink-*` fixtures (19 spec-pure, byte-for-byte
against the spec, plus six composite shapes incl. spec example 526's
link-text precedence and image-alt flattening); six unit tests; smoke
additions (30k URI, 20k email, 10k near-miss scans, one 200 KB
content run, 20k mixed workload — all linear). The whole prior suite
passes unchanged (73 module + 6 fixture tests).
