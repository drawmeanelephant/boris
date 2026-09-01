---
published_at: 2026-08-12T00:00:00Z
summary: Contract for emphasis and strong emphasis, plus code spans, links, images, and autolinks on the scan-match-emit seam.
---

# Oliver Inline Parsing: Emphasis and Strong Emphasis

**Status: implemented (Markdown), with code spans (§6.6), inline links
(§6.6), inline images (§6.7), autolinks (§6.8), reference links, and
reference-style images (§4.7 + §6.6 reference forms) landed on the
same scan → match → emit seam.** This
document waswritten *before* any delimiter code existed, as the design contract; the
implementation in `src/markdown.zig` (scan → match → emit,
`openers_bottom` pruning) follows it, and the §15 fixture corpus plus the
span unit tests lock the behavior. Images share the link discovery pass
(`![` is its own bracket-stack opener with the appendix's active/inactive
semantics) and flatten their description to an arena-owned `alt` string;
their algorithm is the separate contract docs/IMAGES-PARSING.md (also
written before its code).
Code-span discovery (§6.6, the first delimiter-opacity rule) runs ahead
of delimiter scanning: backtick strings are resolved and marked opaque
before `*`/`_` runs are classified. Inline-link discovery is the second
opacity rule, a discovery pass between scan and match with its own bracket
stack: unescaped `[`/`]` become scan items, a `]` whose nearest `[` is
followed by a valid `(...)` splices the range into a `link` item, every
earlier `[` dies (links cannot contain links), and link text is matched as
a fresh inline scope (the spec's "process emphasis with the `[` opener as
stack_bottom"). When the spliced range's last item extends past the
closing paren/`]` (e.g. `[foo](/uri) and more`), its tail is re-appended
as literal text **after** the shrink that consumes the construct — a bug
that previously dropped all inline content after a link (`table-inline-content`
and `link-trailing-text` fixtures lock this). Reference links required a two-phase restructure: link
reference definitions (§4.7) are collected during the block pass (before
any inline parsing, since a use may precede its definition), and the
inline pass then resolves the full `[text][label]`, collapsed `[text][]`,
and shortcut `[text]` forms against that map in discovery — labels are
Unicode case-folded with whitespace collapsed per §6.3. Both land exactly
as the §17 implementation order predicted. Textile inline markers (`_`/`*`/`**`/`__`) are a later
milestone and will ride the same seam. Every deliberate choice below that
the implementation deviates from — the two §16 open questions, the
contiguous-text merge rule, and the front/back consumption model in §8.3 —
is recorded at the point of deviation.

---

## 1. Purpose

CommonMark's emphasis rules are the hardest part of its inline grammar to
get right from prose. They are deliberately *not* a regex or a
balanced-parens algorithm: flanking depends on the characters adjacent to a
run of `*`/`_`, matching is constrained by run lengths mod 3, and strong vs
emphasis must be chosen without backtracking over the whole stream.

This document fixes, in one place:

1. the exact specification text Oliver implements (§6.2 definitions and
   rules, quoted verbatim);
2. a mechanical classification of delimiter runs;
3. a matching rulebook;
4. Oliver's own scan → match → emit algorithm derived from that rulebook;
5. how the algorithm slots into the existing escape and break handling.

It deliberately does **not** describe a specific existing parser's
implementation. Where the spec text is ambiguous or where known
implementations diverge from it, Oliver chooses the spec reading and records
the choice (§14).

---

## 2. Clean-room sources

Only specification-level material was consulted:

- CommonMark Spec 0.31.2, `https://spec.commonmark.org/0.31.2/` (HTML) and
  `spec.txt`. §2.1 (character classes), §2.3 (insecure characters), §2.4
  (backslash escapes), §2.5 (entity references), §4.2 (ATX headings), §6.2
  (emphasis and strong emphasis), §6.7 (hard line breaks).
- CommonMark Spec 0.30, `https://spec.commonmark.org/0.30/` (the §6.2
  definitions and rules are textually identical in 0.30 and 0.31.2; this was
  cross-checked).
- The spec's own discussion forum, `talk.commonmark.org`, used only to
  confirm the wording of the rule text and the spec author's description of
  the algorithm's `openers_bottom` mechanism (threads 2394, 3866). These are
  statements by the spec author about the specification, not parser
  implementation source.
- Stack Overflow answer 77558710 (by way of the Stack Exchange API), which
  quotes the §6.2 rules verbatim from the spec; used as a secondary check on
  the rule text.

No parser implementation source (cmark, markdown-it, goldmark, etc.) was
inspected, searched, or quoted. See `docs/CLEANROOM.md` for the standing
rule.

**Version note.** Example numbering in §6.2 changed between spec versions
(0.29 → 0.30 regrouped examples under rules). This document cites examples
by *input and expected output*, not by example number.

---

## 3. Character classes (spec §2.1)

Three classes drive everything below. Quoted verbatim from 0.31.2 §2.1:

> A Unicode whitespace character is a character in the Unicode Zs general
> category, or a tab (U+0009), line feed (U+000A), form feed (U+000C), or
> carriage return (U+000D).

> A Unicode punctuation character is a character in the Unicode P
> (puncuation) or S (symbol) general categories.

(The spec spells "puncuation"; Oliver follows the standard categories P and
S.)

> An ASCII punctuation character is !, ", #, $, %, &, ', (, ), *, +, ,, -,
> ., / (U+0021–2F), :, ;, <, =, >, ?, @ (U+003A–0040), [, \, ], ^, _, `
> (U+005B–0060), {, |, }, or ~ (U+007B–007E).

Oliver already has `isAsciiPunctuation` in `src/markdown.zig`. The delimiter
milestone adds a `Unicode` classifier (whitespace and punctuation per the
categories above). Practical note for the slice: U+0000 is replaced by U+FFFD
(§2.3) — but Oliver defers that replacement to rendering, so the delimiter
scanner never sees U+0000 as a meaningful character; NUL terminates nothing
and opens nothing (it is simply non-whitespace, non-punctuation text). This
divergence is already documented in `docs/ARCHITECTURE.md`.

---

## 4. Delimiter runs (spec §6.2)

Verbatim:

> A delimiter run is either a sequence of one or more `*` characters that is
> not preceded or followed by a non-backslash-escaped `*` character, or a
> sequence of one or more `_` characters that is not preceded or followed by
> a non-backslash-escaped `_` character.

Two things to note:

1. A run is maximal: it ends at any non-`*`/non-`_` character **or** at a
   backslash-escaped `*`/`_`.
2. "Backslash-escaped" is exactly Oliver's existing odd-backslash parity
   check `isEscaped(bytes, i)` in `src/markdown.zig`. An escaped `*` or `_`
   is *literal text*, never part of a delimiter run — consistent with §2.4
   ("escaped characters are treated as regular characters and do not have
   their usual Markdown meanings").

---

## 5. Flanking (spec §6.2)

Verbatim:

> A left-flanking delimiter run is a delimiter run that is (1) not followed
> by Unicode whitespace, and either (2a) not followed by a Unicode
> punctuation character, or (2b) followed by a Unicode punctuation character
> and preceded by Unicode whitespace or a Unicode punctuation character. For
> purposes of this definition, the beginning and the end of the line count
> as Unicode whitespace.

> A right-flanking delimiter run is a delimiter run that is (1) not preceded
> by Unicode whitespace, and either (2a) not preceded by a Unicode
> punctuation character, or (2b) preceded by a Unicode punctuation character
> and followed by Unicode whitespace or a Unicode punctuation character. For
> purposes of this definition, the beginning and the end of the line count
> as Unicode whitespace.

Read these as a two-condition test with a fallback:

- **Left-flanking** = not followed by whitespace, **and** (not followed by
  punctuation, **or** followed by punctuation *and* preceded by
  whitespace/punctuation).
- **Right-flanking** = not preceded by whitespace, **and** (not preceded by
  punctuation, **or** preceded by punctuation *and* followed by
  whitespace/punctuation).

Colloquially: a run flanking *into* text (letters/digits/anything that is
neither whitespace nor punctuation) is flanking; a run hugging an inner
punctuation character is flanking only if something whitespace/punctuation
sits on the far side. The four flanking states are left-only, right-only,
both, neither.

**Oliver mapping.** "The beginning and the end of the line count as Unicode
whitespace" maps onto Oliver's per-line span model: the block pass already
stores raw per-line content spans (`Paragraph.LineRef.content`), and flanking
is computed against the raw span, treating the span's start and end as
whitespace. This makes line starts/ends behave identically to the spec
regardless of what the trimming policy later emits.

### Derived classification table

Each row is derivable mechanically from the definitions; the outputs in the
right column are verified against spec examples.

| input | flanking of the runs | consequence |
| --- | --- | --- |
| `foo*bar*` | both `*` runs: left + right | can open and can close; `foo<em>bar</em>` |
| `5*6*78` | both `*` runs: left + right | can open and can close; `5<em>6</em>78` (intraword `*` works) |
| `* a *` | both `*` runs: neither | inert; literal `* a *` |
| `*foo*` | first: left-only; second: right-only | `*foo*` → `<em>foo</em>` |
| `foo_bar_baz` | both `_` runs: left + right | single `_` can neither open nor close (rules 2, 4); literal |
| `_foo bar_` | first: left-only; second: right-only | `_foo bar_` → `<em>foo bar</em>` |
| `5__6__78` | both `__` runs: left + right | double `__` can neither open nor close (rules 6, 8); literal |
| `пристаням_стремятся_` | `_` between letters | inert; literal |

The spec has its own delimiter-run example table in §6.2; during
implementation the fixture corpus should mirror it (self-contained
input/output pairs, per the convention above).

---

## 6. The matching rulebook (spec §6.2, rules 1–12)

Verbatim (identical in 0.30 and 0.31.2):

> Rule 1: A single `*` character can open emphasis iff it is part of a
> left-flanking delimiter run.
>
> Rule 2: A single `_` character can open emphasis iff it is part of a
> left-flanking delimiter run and either (a) not part of a right-flanking
> delimiter run or (b) part of a right-flanking delimiter run preceded by a
> Unicode punctuation character.
>
> Rule 3: A single `*` character can close emphasis iff it is part of a
> right-flanking delimiter run.
>
> Rule 4: A single `_` character can close emphasis iff it is part of a
> right-flanking delimiter run and either (a) not part of a left-flanking
> delimiter run or (b) part of a left-flanking delimiter run followed by a
> Unicode punctuation character.
>
> Rule 5: A double `**` can open strong emphasis iff it is part of a
> left-flanking delimiter run.
>
> Rule 6: A double `__` can open strong emphasis iff it is part of a
> left-flanking delimiter run and either (a) not part of a right-flanking
> delimiter run or (b) part of a right-flanking delimiter run preceded by a
> Unicode punctuation character.
>
> Rule 7: A double `**` can close strong emphasis iff it is part of a
> right-flanking delimiter run.
>
> Rule 8: A double `__` can close strong emphasis iff it is part of a
> right-flanking delimiter run and either (a) not part of a left-flanking
> delimiter run or (b) part of a left-flanking delimiter run followed by a
> Unicode punctuation character.
>
> Rule 9: Emphasis begins with a delimiter that can open emphasis and ends
> with a delimiter that can close emphasis, and that uses the same character
> (`_` or `*`) as the opening delimiter. The opening and closing delimiters
> must belong to separate delimiter runs. If one of the delimiters can both
> open and close emphasis, then the sum of the lengths of the delimiter runs
> containing the opening and closing delimiters must not be a multiple of 3
> unless both lengths are multiples of 3.
>
> Rule 10: Strong emphasis begins with a delimiter that can open strong
> emphasis and ends with a delimiter that can close strong emphasis, and
> that uses the same character (`_` or `*`) as the opening delimiter. The
> opening and closing delimiters must belong to separate delimiter runs. If
> one of the delimiters can both open and close strong emphasis, then the
> sum of the lengths of the delimiter runs containing the opening and
> closing delimiters must not be a multiple of 3 unless both lengths are
> multiples of 3.
>
> Rule 11: A literal `*` character cannot occur at the beginning or end of
> `*`-delimited emphasis or `**`-delimited strong emphasis, unless it is
> backslash-escaped.
>
> Rule 12: A literal `_` character cannot occur at the beginning or end of
> `_`-delimited emphasis or `__`-delimited strong emphasis, unless it is
> backslash-escaped.

### Reading the rules

- **Rules 1–4** classify a run for *emphasis* (consume 1 delimiter).
- **Rules 5–8** classify a run for *strong emphasis* (consume 2 delimiters).
  A run of length ≥ 2 can provide a double; a run of length ≥ 1 can provide
  a single. Rules 5–8 state that the *run's* flanking decides, so a `***`
  run is a valid double-opener wherever it is a valid opener.
- The `_` rules (2, 4, 6, 8) are stricter: a `_` that is flanking on *both*
  sides (intraword) can neither open nor close; the (b) clauses carve out
  the punctuation-adjacent cases (e.g. `foo-_(bar)_`), where a both-flanking
  `_` can act if it sits next to punctuation on the correct side.
- **Rules 9/10** are the *match* tests, applied when a closer meets a
  candidate opener: same character, distinct runs, and — only when at least
  one run can both open and close — the run-length mod-3 constraint.
- **Rules 11/12** forbid an unescaped literal delimiter of the matching
  character at a span boundary; in Oliver's algorithm this falls out of how
  strong-vs-emphasis is chosen when a run is long enough for both (§8.4),
  and is pinned by fixtures.

### Verified worked examples

These outputs are verified against spec examples (0.31.2 §6.2) and are the
first fixtures the implementation must hit:

| input | expected |
| --- | --- |
| `*foo bar*` | `<em>foo bar</em>` |
| `foo*bar*` | `foo<em>bar</em>` |
| `5*6*78` | `5<em>6</em>78` |
| `* a *` | `* a *` (literal) |
| `_foo bar_` | `<em>foo bar</em>` |
| `foo_bar_baz` | `foo_bar_baz` (literal) |
| `5__6__78` | `5__6__78` (literal) |
| `пристаням__стремятся__` | literal |
| `*foo**bar**baz*` | `<em>foo<strong>bar</strong>baz</em>` |
| `*foo**bar***` | `<em>foo<strong>bar</strong></em>` |
| `**foo*bar*baz**` | `<strong>foo<em>bar</em>baz</strong>` |
| `**foo*bar**` | `<strong>foo*bar</strong>` |
| `*****Hello*world****` | `*****Hello<em>world</em>***` (see §14.1) |

The mod-3 mechanics are visible in `*foo**bar**baz*`: the middle `**` cannot
close against the first `*` (1 + 2 = 3, a multiple of 3, and not both lengths
multiples of 3), so it opens instead; the second `**` closes it (2 + 2 = 4);
the trailing `*` then closes the first (1 + 1 = 2).

---

## 7. Algorithm overview

Oliver's inline pass becomes two phases inside one arena-backed document
(the block pass is unchanged):

```text
block pass (existing)                 inline pass (new)
raw per-line content spans ──► scan ──► flat item list ──► match ──► emit
                                 (per block,          (delimiter        (document
                                  escape/break/       stack)            nodes)
                                  delimiter detect)
```

The current single-pass immediate-emit design (`emitTextRuns`) cannot host
delimiter matching: flanking needs the *next* character after a run, and
matching needs the whole stream. That is the reason the restructure is
required, and it is the reason `emitTextRuns` is explicitly provisional.

No new top-level parsing entry point: `oliver.parse` and the block pass stay
as they are; only the inline step for paragraphs and headings changes.

---

## 8. The algorithm

### 8.1 The flat inline item list

For one block's content, the scan produces a transient, arena-allocated
list of items:

```zig
const Item = union(enum) {
    /// A run of literal text with escapes already resolved out of it.
    /// `span` may cover a single escaped character (existing convention).
    text: source.Span,
    /// A maximal, non-escaped * or _ run.
    delimiter: DelimiterRun,
    /// A soft or hard line break between two lines of the block.
    brk: BreakKind,
};

const DelimiterRun = struct {
    ch: u8,            // '*' or '_'
    len: u32,          // run length in bytes
    span: source.Span, // full run in the source
    can_open_em: bool,
    can_close_em: bool,
    can_open_strong: bool,
    can_close_strong: bool,
};
```

The list is linear in input size, items hold spans (no copies), and it dies
with the document arena — no separate ownership.

### 8.2 Scan phase (per block, per line)

Walking the raw content span of each line left to right:

1. **Escapes** — at `\` + ASCII punctuation, resolve as today
   (`emitTextRuns` logic): emit a `text` item for the escaped character
   alone. The escaped character is *not* a delimiter (§4).
2. **Delimiter runs** — at a non-escaped `*` or `_`, consume the maximal
   run (stop at a non-`*`/non-`_` byte **or** an escaped `*`/`_`, per the
   run definition). Compute flanking from the byte before the run and the
   byte after it, with the line-span start/end treated as Unicode
   whitespace (§5). Classify with rules 1–8 into the four `can_*` flags.
3. **Everything else** — accumulate into a `text` item (a literal backslash
   before a non-punctuation byte stays literal, as today).
4. **Line end** — append a `brk` item whose kind comes from the existing
   `analyzeLineEnd` (trailing whitespace run consumed; unescaped trailing
   `\` is a hard break). Trailing whitespace itself is *not* emitted as an
   item: it exists in the raw span (so flanking sees it) but is consumed by
   the break analysis before emission (existing policy, §10).

A single linear pass suffices: flanking needs only the run's immediate
neighbors, which the cursor already has. Classification is O(1) per run.

### 8.3 Match phase (delimiter stack)

Maintain an explicit stack of delimiter-run items that `can_open_em` or
`can_open_strong`. Iterate the flat list left to right:

- **Text and break items**: pushed to the "output cursor" region between
  delimiter runs; they are not matched.
- **A run that cannot close**: if it can open, push it; otherwise ignore.
- **A run that can close** (`can_close_em` or `can_close_strong`): search
  the stack **from the top down** for the nearest run of the same character
  that can open, satisfying:

  1. same character (rules 9/10);
  2. distinct run (guaranteed by the stack);
  3. **mod-3 test** — if either run can both open and close (the *applicable*
     kind), the sum of the two runs' lengths mod 3 ≠ 0, unless both lengths
     are ≡ 0 mod 3 (rules 9/10). Whether the test uses the run's original
     length or its remaining length after splits is ambiguous in the rule
     text; see §16.4.

  Then choose strong vs emphasis:

  1. **Strong, if possible**: the closer has ≥ 2 delimiters available and
     `can_close_strong`; the opener has `can_open_strong`; the mod-3 test
     (rule 10) passes for consuming 2 + 2. Consume 2 from the end of each
     run.
  2. **Else emphasis, if possible**: the closer has ≥ 1 available and
     `can_close_em`; the opener has `can_open_em`; the mod-3 test (rule 9)
     passes for consuming 1 + 1. Consume 1 from the end of each run.
  3. **Else no match**: the closer cannot match this opener; continue
     searching down the stack (with the pruning in §8.5).

- **Run splitting**: classification is computed **once per run at scan
  time** (rules 1–8, from the run's original neighbors) and applies to every
  delimiter in the run. Matches consume delimiters from the *end* of a run,
  so a remainder of length ≥ 1 keeps the run's original classification and
  can act as a fresh single delimiter (≥ 2 for a double) with no
  reclassification pass. Example: `***foo** bar*` consumes `**` from the
  `***` opener for strong, leaving `*`, which then opens the emphasis
  closed by the final `*` (`<em><strong>foo</strong> bar</em>`).
- **When a match is made**: wrap every item strictly between the opener's
  consumed bytes and the closer's consumed bytes in one `emphasis` or
  `strong` node. A leftover-run item remains on the stack (it can still
  open); a fully-consumed opener is popped. A run that can both open and
  close and was used as a closer is *not* re-eligible as an opener for
  earlier candidates: a used closer's leftover, if any, sits at the start
  of the closer's run (before its consumed bytes) and can only participate
  in matches with later content. The stack only ever holds runs that have
  not yet been fully consumed as openers.
- **Rules 11/12 by construction**: when a closer can do both strong and
  emphasis, strong wins whenever rule 10 permits (it consumes two, leaving
  no literal single delimiter at the boundary). The literal-boundary
  examples (`**foo bar **`, `***` leftovers) are pinned by fixtures; this
  is the one place implementation experience may refine the statement
  (§16).

Nesting falls out of the stack: an inner match consumes the nearest opener,
so `*foo **bar** baz*` yields `<em>foo <strong>bar</strong> baz</em>`.

### 8.4 Emit phase

Walk the matched flat list and materialize document nodes:

- `text` items → existing `text` nodes (span, borrowed slice); text is split
  at delimiter boundaries, so a run's neighbors become separate text nodes
  with exact spans — the same convention escapes already use.
- matched ranges → `emphasis` / `strong` nodes whose children are the nodes
  emitted for the wrapped items; node span covers the whole construct, from
  the opener's **first consumed byte** through the closer's **last consumed
  byte** (so a split opener's leftover bytes lie *outside* the span —
  consistent with how the paragraph node spans its whole content).
- leftover (unmatched) delimiter bytes are literal *characters*: they
  belong to the adjacent text node and its span covers them. Only
  *consumed* delimiter bytes are covered by no node (the emphasis/strong
  node's children stop at the delimiters).
- `brk` items → `soft_break` / `hard_break` nodes, exactly as today.

Emission is iterative: the match phase produces a tree of spans, and
materialization walks it with an explicit stack (the document's
`Iterator`-style discipline). No call-stack recursion proportional to
nesting.

### 8.5 The `openers_bottom` pruning

The stack search must not rescan the whole stack for every closer (that is
O(n²) on adversarial input like `*a *b *c ...`). Per the algorithm the spec
appendix describes (and the spec author's own explanation in
talk.commonmark.org thread 3866): for each key `(character, closer_length
mod 3)`, remember the lowest stack index that still needs to be searched for
that key; once a closer of that key fails to find an opener above that
bottom, raise the bottom to the closer's position. This makes matching
amortized O(n).

**Divergence to record** (§14.1): the appendix's pruning as implemented by
cmark ignores that the mod-3 constraint applies *only* when one of the two
runs can both open and close, which produces the `*****Hello*world****`
anomaly (thread 3866; the spec author called it a likely bug in the
implementation). Oliver implements the *rules* (9/10), not the pruning bug:
pruning is applied only for key-len pairs where the constraint genuinely
applies, and `*****Hello*world****` → `*****Hello<em>world</em>***` becomes
a pinned fixture.

---

## 9. Interaction with backslash escapes (existing §2.4 handling)

The scan reuses the existing escape logic unchanged; delimiters add no new
escape cases, only a *consumption rule*:

- `\*` → literal `*`, never a delimiter (run definition §4; the escaped
  character is already emitted as its own text node).
- `\\*` → literal `\` followed by a real delimiter run (spec example 15
  shape: `\\*emphasis*` → `\<em>emphasis</em>`).
- A backslash-escaped delimiter terminates a run: `a*\*b` is one run `*`
  (between `a` and the escaped `*`); the escaped `*` is literal; `b` is
  text. There is no second run.
- A backslash before a non-ASCII-punctuation byte is a literal backslash
  and does not escape anything (existing behavior; §2.4 example 13).

**Open question (fixture during implementation):** flanking looks at the
character after a run; when that character is a backslash-escaped `*`/`_`
(e.g. `foo*\*`), Oliver treats the escaped character as its literal
character — a `*` is ASCII/Unicode punctuation — for flanking purposes
(§2.4: "escaped characters are treated as regular characters"). This is the
only reading consistent with the spec text; it is pinned with a fixture.

---

## 10. Interaction with line breaks (existing §6.7 handling)

- An **unescaped trailing backslash** is consumed by `analyzeLineEnd` as a
  hard break (§6.7, example 16). It therefore never becomes an escape of a
  following line's content and never becomes a delimiter. This is already
  true today and is unchanged.
- **Trailing whitespace** is consumed by `analyzeLineEnd` and never emitted,
  but it *remains in the raw line span*, so flanking correctly sees a run
  followed by spaces as not left-flanking (a trailing `*` can close but
  never open; §5 line-end rule).
- **Breaks are items in the stream.** Matching is not interrupted by them:
  `*foo\nbar*` yields `<em>foo\nbar</em>` (soft break inside emphasis), and
  `*foo  \nbar*` yields `<em>foo<br />\nbar</em>`. Delimiter runs are
  per-line (the run definition never crosses a line terminator, since the
  terminator is not `*`/`_`); only *matching* spans lines. Fixture-confirm
  during implementation; this is the behavior the spec's inline model
  implies (see setext example 81: `<h1>Foo <em>bar\nbaz</em></h1>`).
- `isEscaped` already documents that escape parity never leaks across lines;
  the delimiter scan inherits that guarantee (a run at the end of one line
  and the start of the next are separate runs).

---

## 11. Interaction with headings

- ATX heading content is parsed by the same inline pass (spec §4.2: heading
  contents "parsed as inline content"). `# foo *bar*` must produce
  `<h1>foo <em>bar</em></h1>`.
- A terminal backslash in ATX content remains literal: hard breaks separate
  inline content and cannot occur at the end of a block (example 646).
- Setext headings use the same inline pipeline over their content-line spans;
  the excluded underline is not a following content line, so a final
  backslash remains literal there too (example 90).

---

## 12. Future interactions (recorded, not implemented)

- **Entity references (§2.5):** `&#42;` is *not* a delimiter (spec example
  37: `&#42;foo&#42;` → literal `*foo*`). Entity decoding (docs/ENTITIES.md)
  is render/emit-time only — the scan keeps delimiters strictly byte-based,
  so only a literal source `*` or `_` can begin a run. Same for structural
  positions: `&#42;` cannot be a list marker, thematic-break byte, or
  fence/info marker. Verified by the §2.5 examples (11/11).
- **Autolinks and raw HTML:** per the spec's inline precedence (§3.1 and
  the appendix), code spans, autolinks, raw HTML, and links are identified
  *before* emphasis matching; delimiters inside them are inert (e.g.
  `` `*` `` is a code span, not an opener). Code spans (backtick discovery
  in scan) and links (bracket discovery between scan and match) are
  implemented; autolinks land as a `<` recognizer in the same scan
  (docs/AUTOLINKS.md), and raw HTML is discovered over the whole paragraph
  and merged with code spans before that scan (docs/RAW-HTML.md). This is why
  the scan must remain a real tokenizer rather than a tower of regexes.
- **Textile:** the roadmap maps Textile `_`/`*`/`**`/`__` onto the same
  document nodes. The scan → match → emit pipeline and the stack are
  dialect-agnostic; the *classification rules* (flanking, intraword policy)
  are dialect-owned and will be defined from Textile documentation, not from
  CommonMark, in the Textile milestone.

---

## 13. Model and renderer impact

- `document.Tag` gains `emphasis` and `strong` (already listed in the
  `docs/DOCUMENT-MODEL.md` growth path). They carry no `Data`.
- **Invariant change:** today invariant 4 reads "inline tags (`text`,
  `soft_break`, `hard_break`) have no children." `emphasis`/`strong` are
  inline tags *with* inline children. The invariant becomes: leaf inline
  tags (`text`, breaks) have no children; `emphasis`/`strong` contain
  inlines. `docs/DOCUMENT-MODEL.md` must be updated when the tags land.
- `Tag.isInline` gains the two tags. `Document.Iterator` already handles
  arbitrary depth with an explicit stack — no change.
- `src/html.zig` emits `<em>` / `<strong>` around children; text escaping
  inside is the existing policy (no new escaping questions). Renderer tests
  already operate on hand-built documents; hand-built `emphasis`/`strong`
  fixtures are added alongside parser fixtures.

---

## 14. Deliberate choices and recorded divergences

1. **`openers_bottom` pruning (§8.5).** Oliver follows rule 9/10's text
   (the mod-3 constraint applies only when a run can both open and close)
   over the appendix's pruning description as realized in cmark, which the
   spec author called a likely implementation bug. Fixture:
   `*****Hello*world****`.
2. **Strong-before-emphasis.** When a closer can close both, strong wins if
   rule 10 permits. This is what rules 11/12 require in the classic cases;
   it is pinned by the verified examples in §6.
3. **Flanking sees the raw span, emission sees the trimmed content.** The
   scan reads the raw per-line span (so trailing whitespace and line
   boundaries flank correctly) while emission obeys `analyzeLineEnd`'s
   consumed range. Recorded because the paragraph-trimming policy will
   change when indented code blocks land (matrix); flanking is defined
   against the raw span and will not change.
4. **Escaped characters count as their literal character for flanking** (§9
   open question). Chosen reading; fixture-pinned.
5. **Intraword `*` is permitted, intraword `_` is not** — that asymmetry is
   the spec's (rules 1 vs 2, 3 vs 4) and is reproduced mechanically; no
   special-case code.

---

## 15. Test plan

Following the tests-as-contract conventions in `docs/TESTS.md`, for both
dialects' fixture sets (Markdown first):

- **Simplest:** `*foo*`, `**foo**`, `_foo_`, `__foo__`, mixed
  `*foo **bar** baz*`.
- **Intraword:** `foo*bar*`, `5*6*78`, `foo_bar_baz`, `5__6__78`,
  `пристаням__стремятся__`, `foo-_(bar)_`.
- **Whitespace:** `* a *`, `*foo bar*`, `foo * bar`, `*`/`_` at line
  start/end, runs adjacent to trailing-space consumption.
- **Ambiguous / mod-3:** `*foo**bar**baz*`, `*foo**bar***`,
  `**foo*bar*baz**`, `**foo*bar**`, `***foo** bar*`, `foo***bar***baz`,
  `*****Hello*world****`.
- **Malformed:** `** is not an empty emphasis` (literal), `**** is not
  empty strong` (literal), stray `*`, unbalanced runs at paragraph end.
- **Escapes:** `\*foo*`, `\\*foo*`, `a*\*b` (flanking fixture, §9).
- **Breaks:** `*foo\nbar*`, `*foo  \nbar*`, `foo\` followed by `*bar*`.
- **Headings:** `# foo *bar*`, `# *foo* \#` (escape-aware closing already
  exists).
- **Spans:** for `*foo*`, the `emphasis` node's span covers
  `[0, 5)`; the inner text node `[1, 4)`; consumed delimiters covered by no
  node. Asserted in unit tests, not fixtures.
- **Unicode:** `пристаням_стремятся_`, emoji-adjacent runs (U+FE0F/U+20E3
  sequences are *text*, not punctuation — they are neither P nor S), full-
  width punctuation as the flanking punctuation case.
- **Adversarial (extend the smoke test):** 100 KB of `*`, deep `*a *b *c`
  nesting, alternating `*`/`_` runs, NUL bytes — no hang, no crash, no
  stack overflow, no quadratic blowup (the `openers_bottom` pruning is what
  keeps this linear; the smoke test asserts completion, timing is checked
  manually).
- **Renderer-only:** hand-built `emphasis`/`strong` documents rendered
  without parsing (existing direct-render test pattern).

---

## 16. Open questions (resolved during implementation, each gets a fixture)

1. Escaped-character-as-punctuation for flanking (§9) — chosen reading, to
   be confirmed against a spec example if one exists, otherwise recorded as
   a deliberate Oliver behavior.
2. Whether rules 11/12 require anything beyond the strong-before-emphasis
   preference (§8.3) in a corner case; if a counterexample appears in the
   spec's example corpus, the matching loop is adjusted and the fixture set
   is extended. This is the one place the doc may be refined by
   implementation experience.
3. Exact per-rule example grouping in 0.31.2's fixture corpus — the corpus
   cites inputs and outputs, so numbering drift does not matter.
4. **Mod-3 length basis (§8.3).** Rule 9/10 speak of "the lengths of the
   delimiter runs containing the opening and closing delimiters". For a run
   split by an earlier match, that is most literally the *original* run
   length; the *remaining* length coincides on every verified example in
   §6. Implementation must find or construct an input where the two
   readings diverge, pin the chosen reading against the spec's own example
   corpus (or, if the corpus does not decide, record the literal reading as
   the deliberate choice), and add the fixture.

---

## 17. Implementation order (next slice)

1. Add `emphasis`/`strong` to `document.Tag` (+ `isInline`), update
   `docs/DOCUMENT-MODEL.md` invariant 4.
2. Add the Unicode classifier (whitespace, punctuation per §3).
3. Restructure the inline pass into scan → match → emit inside
   `src/markdown.zig`, reusing `emitTextRuns`, `analyzeLineEnd`,
   `skipLeadingWhitespace`, `isEscaped` unchanged; paragraphs and headings
   share the pass.
4. Implement the delimiter stack with `openers_bottom` per §8.5.
5. Add `<em>`/`<strong>` to `src/html.zig` (both from parser-produced and
   hand-built documents).
6. Land the §15 fixture corpus and the span unit tests; run the adversarial
   smoke additions.
7. Re-run `zig fmt --check`, `zig build`, `zig build test`; update
   `docs/FEATURE-MATRIX.md` and this document's status line.
