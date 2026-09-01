---
published_at: 2026-08-12T00:00:00Z
summary: Design contract for reference-style images (sections 6.4/6.7) in Oliver's Markdown frontend.
---

# Oliver Inline Parsing: Reference-Style Images (§6.4/§6.7)

**Status: design note (written before any code).** This document is the
contract for the reference-style-image slice of Oliver's Markdown
frontend: the full, collapsed, and shortcut image forms (`![alt][label]`,
`![alt][]`, `![alt]`). It is derived entirely from the CommonMark
specification (0.31.2) and Oliver's own docs, and it is written *before*
implementation, like docs/INLINE-PARSING.md (emphasis),
docs/IMAGES-PARSING.md (inline images), and the reference-links slice
already on main.

Clean-room note: only specification text (the CommonMark 0.31.2 `spec.txt`
and numbered HTML) and Oliver's own docs were consulted. No parser
implementation source was read, searched, or imitated.

## 1. Why this slice exists, and what is already on main

The images milestone (docs/IMAGES-PARSING.md) deferred the reference-style
forms; the reference-links milestone (merged on main via the parallel
slice) implemented §4.7 link reference definitions and the three reference
forms for **links** — and explicitly left the *image* reference forms
gated off in the shared discovery pass (the `!is_image` guards in
`discoverLinksAndImages`). This slice removes exactly that gate: reference
forms for `![` openers, reusing the existing definition table, the image
discovery pass, and the alt-flattening emit path that the inline-images
milestone already built.

The spec's *look for link or image* appendix procedure treats links and
images uniformly on a closing `]`; the only differences are the `!` in the
opener and what happens to the bracket-range content afterwards (link text
becomes children; an image description is flattened to the `alt` string at
emit time). Both behaviors already exist on main — for links on the
reference branches, for images on the inline branch. This slice needs **no
new model surface and no new renderer surface**: a reference-style image is
the same `.image` node as an inline image, with `data.image = { src, alt,
title }` resolved from the matched definition.

## 2. The four forms, in the appendix's order

On a `]` whose nearest opener is active (see docs/IMAGES-PARSING.md §2 for
the active/inactive rule), the procedure tries, in order:

1. **Inline** — `(...)` immediately after the `]` (existing
   `tryParseLink`; unchanged).
2. **Full reference** — a link label immediately after the `]` (first char
   `[`) whose normalized form matches a definition: `![alt][label]`. The
   `[label]` bytes are consumed; src/title come from the definition.
3. **Collapsed reference** — the string `[]` immediately after the `]`,
   with the opener's own bracket text as the label: `![alt][]` ≡
   `![alt][alt]`.
4. **Shortcut reference** — the opener's own bracket text as the label,
   used only when the `]` is **not** followed by `[]` or a link label
   (any `[` after the `]` — valid label or not — takes the full-reference
   path exclusively; a failed full reference is *not* retried as a
   shortcut, per the `[foo][ref[]` example).

This is the identical ordering the reference-links slice already
implements for `[` openers; the change is purely that `![` openers take
the same branches.

### The inactive-bracket rule applies unchanged

A formed **link** (any of the four forms) inactivates every earlier `[`
opener; a formed **image** — including a reference-style image —
inactivates nothing (`![` openers are never inactive). The monotone
O(1) `max_link_opener_out` check on main already implements this; the
reference-image branches must simply not update that marker, exactly as
the inline-image branch does not.

### Description content

The description (bracket-range content) of a reference-style image is
matched as a fresh inline scope, exactly like the inline image's — it may
contain links and images, and never another link. At emit time it is
flattened to the `alt` string by the existing `flattenAlt` path, with the
chosen behaviors already recorded in docs/IMAGES-PARSING.md §3/§8
(emphasis/strong drop markers, breaks → `\n`, code spans → normalized
content, escapes resolve). The reference label itself is normalized
*matching* text, not parsed content — `[foo\!]` and `[foo!]` are
different labels (§6.3).

## 3. Chosen behaviors and recorded divergences

1. **Definitions, matching, first-wins, and the 999-codepoint label cap
   are all inherited** from the reference-links slice; nothing new is
   invented here. Matching is on normalized strings: Unicode case fold
   (full, including multi-codepoint expansions) + whitespace collapse.
2. **Entities decode in reference-image destinations/titles/alt** — the
   shared §2.5 machinery (docs/ENTITIES.md), same as links and inline
   images; the recorded "entities stay literal" divergence is gone.
3. **A failed full reference is not retried as a shortcut** for images,
   exactly as for links (the appendix's ordering, pinned by the
   `[foo][ref[]`-style shape).
4. **The repo's section numbering convention** is kept: the numbered
   0.31.2 HTML calls the images section §6.4, but Oliver cites it as
   §6.7 (recorded in docs/IMAGES-PARSING.md §8, matrix ambiguity #13).

## 4. Verification and test plan

1. Verify the §6.4 reference-image examples byte-for-byte through the CLI
   before writing fixtures (spec examples 582–591 in the numbered HTML:
   full, collapsed, shortcut, case-insensitive labels, image-in-link-text,
   and the literal non-matching shapes). Examples depending on features
   outside the slice are recorded skips, matching the existing
   divergences.
2. Fixtures: `ref-image-*.md`/`.html` — full, full with case-folded label,
   collapsed, collapsed with emphasis in description (alt flattening),
   shortcut, shortcut with alt, image inside reference-link text,
   inline-beats-reference precedence, and malformed/unmatched → literal.
3. Unit tests: reference-image resolution and precedence (full > collapsed
   > shortcut, inline first), alt flattening through the reference forms,
   the inactive-bracket rule through a reference image, and the
   definition-after-use shape for images.
4. Adversarial smoke: reference-image forms join the existing link/image
   bombs (repeated `![x]`/`![x][]`/`![x][x]` lookups share the definition
   table's O(1) lookup and the monotone inactive check — no new
   quadratic surface).
5. Quality gate: `zig fmt --check`, `zig build`, `zig build test` green;
   the whole pre-existing suite must pass unchanged.
