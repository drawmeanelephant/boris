---
published_at: 2026-08-12T00:00:00Z
summary: Operational brief for a delegated agent implementing the inline-images slice of Oliver's Markdown frontend (section 6.7).
---

# Mission brief: Markdown images (§6.7) — for a delegated agent

This is an operational brief. A separate agent (e.g. `codex/agent-2` or
`codex/agent-3`, in their own worktree) implements the **inline images**
slice of Oliver's Markdown frontend. It must be read and executed as a
self-contained mission: clean-room discipline first, a design note second,
code third.

The mission is scoped to land on top of the current `main` (which contains
the founding milestone: paragraphs/headings/escapes/breaks, emphasis/strong,
code spans, inline links). A parallel slice — reference links (§4.7) — is
being built in another agent worktree; this brief deliberately excludes
everything that slice owns.

---

## 0. Clean-room rules (non-negotiable)

Oliver is a **clean-room implementation**. Do not inspect, clone, search,
browse, copy, translate, imitate, or derive implementation techniques from
any existing Markdown/Textile parser source code (cmark, pulldown-cmark,
markdown-it, goldmark, RedCloth, etc.). Do not use GitHub code search for
implementation questions. Do not port algorithms from another language. If
you recognize an implementation technique from prior training, do not
recreate another project's internal architecture from memory.

**Allowed sources:**

- The CommonMark specification (`https://spec.commonmark.org/0.31.2/`, or
  the normative `spec.txt` — a language specification, not an
  implementation). **§6.7 (Images) is the primary source for this mission.**
- The Oliver codebase itself (it is ours) and its docs:
  `docs/CLEANROOM.md`, `docs/ARCHITECTURE.md`, `docs/DOCUMENT-MODEL.md`,
  `docs/INLINE-PARSING.md`, `docs/FEATURE-MATRIX.md`.
- HTML specifications where relevant.

When the spec is ambiguous, record the ambiguity and choose an Oliver
behavior deliberately (see the metadata decision in §3).

## 1. Mission: inline images, exactly one feature

Implement **Markdown inline images** per CommonMark §6.7:

```
![alt text](destination "title")
```

producing the document-model node `.image` and rendering:

```
<p><img src="..." alt="..." title="..." /></p>
```

Scope decisions made **for you** (do not expand):

- **Inline images only.** Reference-style forms — `![alt][label]`,
  `![alt][]`, `![alt]` — require link reference definitions (§4.7), which
  belong to the parallel reference-links slice. They defer. (After both
  slices land, a later slice adds reference-style images; the examples in
  §6.7 that use `[foo]: /url` definitions are *not* part of this mission.)
- **No new metadata syntax.** The spec form carries exactly `src`, `alt`,
  and optional `title`. The metadata *extension point* is designed (§3) but
  no extension syntax is implemented in this mission.
- **`<img>` is a void element.** It renders with the existing
  `void_trailing_slash` policy (`<img src="..." alt="..." />` by default),
  exactly as `<br />` is handled today.
- **Fix the documented divergence.** Today `![foo](bar)` parses as literal
  `!` + a link (FEATURE-MATRIX, "images" row). This mission makes `![` an
  image opener, so `![foo](bar)` is one `.image` node.

## 2. What §6.7 requires (derive from the spec; verify every claim)

Re-read §6.7 in the spec, then use the appendix's "look for link or image"
procedure as the algorithmic contract. The behaviors that matter:

- **`![` is its own opener.** Syntax is like links, but the description
  starts with `![` rather than `[`, and (crucially) **an image description
  may contain links** (and images). Per the appendix, the delimiter stack
  holds `[` and `![` entries; a `]` looks back for the *nearest* opener.
- **Images may contain links and images; links may not contain links.** So
  the current link rule "a formed link kills every earlier `[`" must not
  apply to `![` openers — otherwise `![foo [bar](/url)](/url2)` would break
  (spec example: alt = `foo bar`).
- **Alt text is plain string content.** "Only the plain string content of
  the image description be used" — `![foo *bar*]` renders `alt="foo bar"`,
  `![foo ![bar](/url)](/url2)` renders `alt="foo bar"`, with no formatting
  and no markup. The design note must pin down exactly how the description's
  inlines (emphasis, strong, code spans, soft/hard breaks, escapes) flatten
  into the alt string, with spec examples. The reference emits `alt=""` for
  an empty description (`![](/url)`) — the attribute is present and empty.
- **Escapes matter at the boundary:** `!\[foo]` is literal `![foo]` (the
  `[` is escaped, so no image); `\![foo]` is a literal `!` followed by a
  link (the `!` is escaped).
- **Escaping in attributes:** `src` uses the same percent-encoding +
  HTML-escaping policy as link `href` (docs/ARCHITECTURE.md); `alt` and
  `title` are HTML-escaped like text (the spec example renders
  `title="train &amp; tracks"`).
- **The shared link parser is reused:** destinations and titles parse
  identically to links (`<...>` or bare destinations, `"`/`'`/`(...)`
  titles, separators, the §6.6 DoS guards on paren depth and scan length).
  The existing `tryParseLink` is the template; images reuse it for the
  `(...)` part.

## 3. The metadata design decision (design note deliverable, before code)

The user's roadmap explicitly wants **metadata beyond the spec** in the
images portion eventually (classes, ids, width/height, custom attributes).
That is a model decision, so it is decided on paper first — this mission's
first deliverable is `docs/IMAGES-PARSING.md` (written from the spec,
mirroring how `docs/INLINE-PARSING.md` was the emphasis contract). The note
must:

1. **Derive the image algorithm** from §6.7 + the appendix (opener types,
   the look-for-link-or-image procedure, the inactive-bracket rule as it
   applies to `![` vs `[`, alt flattening) — before writing code.
2. **Decide the model shape for alt.** Two defensible options: (a) `.image`
   keeps the description as inline children and the renderer flattens them
   to the alt string; (b) `.image` carries an arena-owned alt string
   (mirroring `data.link`, which is escape-resolved and arena-owned). Choose
   one, justify it against the DOCUMENT-MODEL invariants (renderer never
   resolves dialect escapes; leaf inlines have no children), and record the
   choice. Recommended direction: (a) children + renderer-side flattening is
   spec-true but pushes text assembly into the renderer; (b) matches the
   existing arena-owned payload pattern. Decide, don't hedge.
3. **Reserve the metadata extension point.** DOCUMENT-MODEL.md already
   reserves `Data.attrs` (an ordered attribute list) for future Textile
   classes/ids/styles and image metadata. The note defines: spec metadata
   (`src`, `alt`, `title`) in this mission; `Data.attrs` is the extension
   point for future metadata; no extension syntax is invented in this
   mission. Record which future metadata kinds are anticipated so the
   extension point is shaped for them, not against them.
4. **Record spec ambiguities** with the chosen Oliver behavior (the
   alt-flattening rules for breaks, the exact `src` percent-encoding, etc.).

The design note is committed before any implementation code, and is the
reviewable contract for the PR.

## 4. Conventions to copy from the link milestone

The link milestone (PR #1, `src/markdown.zig`) is the template. Match its
patterns exactly:

- **The seam:** scan → match → emit. Links were added as a *discovery pass*
  between scan and match (bracket items in the scan, `discoverLinks` with a
  bracket stack, splice into a `link` item, children matched as a fresh
  inline scope). Images extend that same discovery pass with a `![` opener
  and an image splice. Do not invent a parallel pipeline.
- **Model:** `.image` tag in `src/document.zig`; `Data.image` payload
  (`src`, `alt`, `title`) following the arena-owned pattern of `Data.link`.
  Update the module docs, `Tag.isBlock`/`isInline`, and the invariants in
  `docs/DOCUMENT-MODEL.md` (children rules, payload ownership, the
  convergence table: Markdown `![alt](url)` ↔ future Textile `!url(alt)!`).
- **Renderer:** `.image` in `src/html.zig` — `<img src=... alt=... title=...>`
  as a void element under `void_trailing_slash`, attribute escaping per the
  documented policies, `alt` always emitted (possibly empty), `title` only
  when present. Add a renderer-only test (hand-built image node) like the
  link one. Update the module doc's attribute policy.
- **Verification workflow:** pull the normative `spec.txt` (allowed
  source), verify the inline-image examples byte-for-byte through the CLI
  (`zig build run -- render --from markdown`) *before* writing fixtures.
  Then lock each verified example as a fixture.
- **Fixtures:** `tests/fixtures/markdown/image-*.md` + `.html`, byte-exact,
  registered in the `markdown_fixtures` table in `tests/fixtures_test.zig`.
  Cover: simple, title, angle destination, empty alt, escaped `!`/`[`,
  nested images, image-containing-link, alt flattening (emphasis/code),
  image in heading, image in emphasis, unclosed → literal, code-span
  precedence (`` ![foo`](/uri)` `` keeps the span). Where a spec example
  needs §4.7 (reference forms), skip it — record the deferral.
- **Unit tests:** in the `src/markdown.zig` test section — structure and
  spans, alt flattening, nesting (images in links, links in images,
  images in images), escape boundaries, precedence with emphasis and code
  spans, DoS shapes (images share `tryParseLink`, so the existing guards
  must hold — add `![a](`-style smoke cases to the adversarial test).
- **Docs:** update FEATURE-MATRIX (images row: implemented, with the
  reference-forms deferral), INLINE-PARSING.md status line, TESTS.md counts,
  README.md status, and append a session-report addendum. Record every
  chosen behavior/divergence.
- **Quality gate:** `zig fmt --check`, `zig build`, `zig build test` all
  green (currently 53/53); the whole existing suite must pass unchanged.

## 5. Workflow

1. In your worktree: `git fetch origin` and get your branch onto the
   current `origin/main` (rebase or reset; your branch should currently hold
   no content).
2. Read the docs and the link implementation (§0). Re-read §6.7 and the
   appendix from the spec.
3. Write and commit `docs/IMAGES-PARSING.md` (the §3 design note).
4. Implement the model, renderer, and parser changes.
5. Verify against the spec examples; write fixtures, unit tests, smoke
   cases; update docs.
6. Quality gate; push your branch; open a PR against `main` with the design
   note referenced in the description.

## 6. Out of scope (will collide with the parallel slice — do not touch)

- Link reference definitions (§4.7) and *any* reference-style image forms.
- The `reference-links` work in the block pass.
- Any new metadata syntax (extensions land after the design note is
  approved).
- Textile inline mapping, entities, autolinks, raw HTML.
