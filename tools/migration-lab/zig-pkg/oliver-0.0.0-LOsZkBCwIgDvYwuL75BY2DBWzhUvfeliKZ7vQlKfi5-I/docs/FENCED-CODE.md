---
published_at: 2026-08-12T00:00:00Z
summary: Implementation contract for CommonMark section 4.5 fenced code blocks.
---

# Markdown fenced code blocks

**Status:** implementation contract for CommonMark 0.31.2 §4.5.

This design is derived only from the normative CommonMark 0.31.2 prose and
examples for §2.4 backslash escapes, §2.5 entities, §4.5 examples 119–147, the
container rules in §5, and the appendix block-parsing strategy. No parser
implementation source was consulted.

## Syntax and precedence

An opening fence has zero to three leading ASCII spaces followed by at least
three consecutive backticks or tildes. Marker types cannot mix. The remaining
bytes form an optional info string after leading/trailing spaces and tabs are
removed. A backtick-fence info string containing any backtick rejects the
entire opener; tilde-fence info strings may contain backticks and tildes.

Fenced code can interrupt a paragraph and needs no surrounding blank line.
Container markers and list-item indentation are consumed first, so a fence can
open inside a block quote or list item. A fence is an interrupting block for
lazy-continuation decisions: a missing container marker closes the containing
block rather than lazily absorbing the would-be fence into its paragraph.

## Open-leaf state

The block pass keeps at most one open fenced-code leaf alongside its container
stack. The state records:

- marker byte and opening run length;
- opening indentation (zero through three spaces);
- containing stack depth;
- the already-appended `.code_block` node;
- an arena-backed normalized content buffer.

While the leaf is open, container matching still runs first. If fewer than the
recorded containers match, the fence ends at the containing block boundary and
the current physical line is reprocessed normally outside it. Otherwise the
container-stripped view is either a closing fence or literal content; no other
block or inline recognizer runs on it.

A closing fence uses the opening marker byte, has a run at least as long as the
opener, has zero to three leading spaces, and is followed only by spaces or
tabs. Its indentation need not match the opener. A shorter run, other marker,
four-space indent, or suffix text is content. At document or containing-block
end, an unclosed fence closes without backtracking.

## Content, model, and spans

Up to the opening fence's indentation is removed from each content line. Only
available leading ASCII spaces are removed; a less-indented line keeps its
remaining bytes. Content is literal—no inline parsing, escapes, entity
decoding, or raw-HTML interpretation. Each physical content line contributes
one normalized `\n`, including the final unterminated source line. This makes
mixed LF/CRLF/CR input deterministic and requires an arena-owned payload.
When a fence is inside a list item, the matcher first consumes as much of the
item's required indentation as a blank line actually provides; only excess
spaces enter the literal payload. A blank line inside the fence does not alter
the list item's initial-blank or looseness state.

The normalized model gains a leaf block:

```zig
.code_block
data.code_block = .{
    .content = normalized_owned_bytes,
    .info = trimmed_escape_resolved_owned_info_or_null,
}
```

The node span covers the full marker-stripped construct: opening fence,
content, and closing fence when present, excluding only the closing line's
terminator as other block spans do. The payload contains no syntax markers.
Keeping the complete info string, rather than only a language token, preserves
semantic information for future renderers. Backslash escapes and §2.5 entity
references are resolved in the arena-owned payload as the spec requires.

## HTML rendering

The renderer emits `<pre><code>`, escaped literal content, and
`</code></pre>\n`. When an info string exists, its first space/tab-delimited
word becomes `class="language-WORD"` on `<code>`; the word is HTML-escaped as
an attribute value. Remaining info-string words are retained in the model but
do not affect this renderer. Empty content emits no synthetic byte between the
tags; nonempty source lines already carry their normalized trailing newline.

## Complexity and verification

Each source line is matched and scanned a constant number of times. Fence-run,
suffix, indentation, and content work is linear in that line's bytes; content
is appended once. There is no search for a closer, backtracking, recursion, or
reparse of accumulated content.

Acceptance includes:

- both marker types, exact and longer closers, mismatched/short/indented
  near-misses, empty and unclosed blocks;
- opening/content/closing indentation, paragraph interruption, adjacent
  headings/thematic breaks, block quotes, and lists;
- info-string trimming, backslash resolution, language-class escaping, and
  backtick restrictions;
- literal inline-looking/HTML bytes and mixed LF/CRLF/CR normalization;
- exact node span and payload assertions;
- long fence runs, many near closers, and unclosed content rendered
  deterministically under the leak-checking allocator;
- the full suite and the canonical §4.5 scorecard, with indented-code and
  entity dependencies reported rather than hidden.
