# Emoji Kitchen extension — portability design

**Status:** bounded prototype/report only; no product behavior changes

This proposal records the smallest Boris-compatible shape for an optional
Emoji Kitchen-style extension. It intentionally does not add a CDN dependency,
generate HTML by string replacement, or invent a large binary asset corpus.

## Current Boris boundary

Boris currently sends author Markdown through this HTML body sequence:

```text
frontmatter parse
  → bounded includes
  → Boris wiki-link rewrite
  → content-local image rewrite
  → Aside tokenization
  → ApexMarkdown rendering
  → layout assembly
```

The natural extension point is a small Markdown adapter immediately before
Aside tokenization and Apex rendering, after Boris-owned source rewrites. It
must receive Markdown bytes and return Markdown bytes or an explicit error; it
must not inspect or rewrite generated HTML.

The current content-local asset contract publishes opaque files from an exact
`{page-stem}.assets/` sibling tree. Theme assets have a separate inventory and
namespace. Neither contract currently defines an Emoji Kitchen pair manifest,
so this branch deliberately does not add image files or pretend that a remote
asset URL is deterministic.

## Proposed semantic contract

### Syntax

The experimental source form is:

```markdown
!ek[🐢+🔥]
```

The initial contract should accept exactly two operands, each one supported
Unicode scalar from a versioned local manifest. Whitespace around operands may
be ignored. The operand order is significant unless a manifest entry says a
pair is commutative; normalization must never silently reorder author input.

Malformed or unsupported forms remain literal source text. In particular,
arbitrary words, empty operands, more than two operands, unsupported emoji, and
multi-scalar ZWJ sequences are not guessed into assets.

### Context boundaries

The adapter may operate in ordinary Markdown inline text, including headings,
emphasis, link labels, list items, blockquotes, and table cells. The fixture in
`docs/contracts/fixtures/emoji-kitchen-prototype/content/index.md` records these
contexts.

It must leave these contexts byte-for-byte literal:

- inline code spans and fenced code blocks;
- raw HTML tags and attributes;
- image destinations and link destinations;
- already escaped or malformed syntax.

These boundaries require a Markdown-aware scanner. A global replacement over
the source or rendered HTML is not an acceptable implementation.

### Output modes

Two output modes are viable, but only one should be selected by a future
implementation PR:

1. **Local asset mode (preferred for a real feature):** a manifest maps a
   normalized ordered pair to a repository-local image under the configured
   theme or page-local asset namespace. The adapter emits a normal Markdown
   image token, allowing Apex to own HTML escaping. The generated alt text is
   derived from the normalized operands, for example `Emoji Kitchen: 🐢 + 🔥`.
2. **Text fallback mode (prototype-friendly):** the adapter emits visible
   Unicode/text such as `Emoji Kitchen: 🐢 + 🔥` and records that no combined
   artwork was available. This has no binary or network dependency, but it is a
   fallback representation, not a claim that Boris generated a combined image.

Either mode is deterministic. Network fetches, runtime CDN URLs, arbitrary raw
HTML, and silent broken-image fallbacks remain unsupported.

### Escaping and accessibility

Operands are normalized before they are used in a label or asset key. Labels
must pass through the same Markdown/HTML escaping path as ordinary author text.
The local-image mode must provide meaningful alt text; a decorative image is
not a sufficient fallback because the operands carry the semantic content.
The text fallback is inherently visible to assistive technology and must not
be wrapped in a misleading factual or provenance label.

## Why this is not wired yet

The current repository has no approved local Emoji Kitchen manifest or pair
asset set. Adding a handful of copied images would create an accidental,
underspecified corpus; fetching Google/third-party images would violate the
offline and deterministic build boundary. The correct next implementation
card is therefore to choose and contract a small local manifest first, then
add the parser adapter and its golden fixture in a separate PR.

## Recommended implementation cards

1. `codex/emoji-kitchen-manifest-afterparty`
   - define manifest schema and provenance/version fields;
   - choose a deliberately tiny, licensed local fixture corpus;
   - validate pair keys, asset paths, and deterministic inventory order;
   - document text fallback behavior.
2. `codex/emoji-kitchen-extension-afterparty`
   - add a pure fence/code-span-aware parser adapter;
   - keep malformed input literal;
   - emit ordinary Markdown image or text fallback, never raw HTML;
   - add context, escaping, accessibility, and byte-determinism tests.
3. `codex/emoji-kitchen-theme-assets-afterparty` (only if needed)
   - connect the manifest to existing theme/page-local asset publication;
   - prove target isolation and no network access.

These should remain separate from documentation-link conversion, metadata/EXIF,
photographer proof sites, and RAG changes. The parser extension and asset
publication have different contracts and review risks.

## Explicitly unsupported in the first implementation

- arbitrary text operands or “best effort” emoji guessing;
- multi-rune ZWJ sequences and variation-selector policy not in the manifest;
- network/CDN fetching during a build;
- binary rewriting, resizing, or image synthesis;
- source or generated-HTML global substitutions;
- expansion inside code, raw HTML, image URLs, or link URLs;
- automatic graph/RAG metadata emission;
- lore text being treated as creator, provenance, or accessibility metadata.

## Verification bar for a future implementation

The future PR must show:

- ordinary text, headings, emphasis, links, lists, blockquotes, and tables;
- inline/fenced code remaining literal;
- malformed, unsupported, escaped, and raw-HTML cases remaining safe;
- no arbitrary HTML injection and correct alt/label escaping;
- local asset discovery obeying `content-local-assets.md` or the theme asset
  contract;
- sequential output, repeated output, and any supported parallel output being
  byte-identical;
- `zig build`, `zig build test`, hostile/sanitize tests where available, and the
release gate when the implementation touches the HTML contract.
