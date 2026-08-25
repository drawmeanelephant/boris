# Poetry shapes contract

This document is the written contract for verse counting in
`boris-content-audit --mode=poetry`. Every supported shape is defined below
with fixtures. The engine counts **semantic verse units**, never raw
occurrences of obsolete MDX component names such as `<Limerick>` or
`<Broside>`.

## Ground rules (apply to every shape)

1. **Frontmatter is ignored.** The `---\n...\n---` block is excluded before
   counting.
2. **Fenced code is ignored.** Lines inside fenced-code blocks are never
   counted, even if they look like verse. Fences follow Markdown semantics:
   - the opening fence is at least three consecutive backticks (`` ` ``) or
     tildes (`~`);
   - the opening fence character is remembered;
   - an info string is allowed on the **opening** fence (e.g. `` ```text ``);
   - the closing fence must use the **same character** with a **length at
     least** the opening length, and may contain **only ASCII spaces or tabs
     after the fence run** — a line like `` ```not-a-close `` is never a
     closing fence, so a block only closes on a clean `` ``` `` (or
     `` ~~~ ``) line; a clean closer with trailing spaces does close;
   - backtick and tilde fences follow identical rules;
   - an unclosed fence is handled deterministically: every line after the
     opening fence is ignored until end of file, and the ignored content is
     never counted.
3. **Collection-label headings are ignored.** A heading that only labels a
   collection (e.g. `# Haiku`, `## Limericks`) is not a verse unit and does
   not start one. This is determined by the collection-name heading heuristics
   below plus the fact that a heading line never counts as verse content.
4. **Only complete, non-empty units count.** A unit missing its required line
   count is classified as **malformed** and reported separately. A block that
   contains only blank lines is not a unit.
5. **Malformed or partial units are classified separately** in
   `malformed_units`; they never inflate `complete_count`.
6. **Unicode is preserved exactly.** Counting is line- and byte-based; no
   normalization, no case-folding of verse content.
7. **Embedded HTML or directives are never executed.** Tags are treated as
   opaque text; if they appear where verse content belongs they are simply
   line content. Only the placeholder signature check (below) treats text
   specially, and it does not execute anything.
8. **Unregistered shapes are never analyzed.** A poetry type without a
   registered shape is reported with an `unregistered_poetry_shape` structural
   exception, its verse shape is classified malformed/unsupported, and its
   lines are **never** counted as paragraph units and never grant substantive
   coverage (see “Unsupported shapes” below).

## Shape inventory

The registered shapes are defined in `src/verse.zig` and are keyed by poetry
type from the policy's `poetry_collections`. Types without a registered shape
are **never analyzed as paragraph units**: they emit an
`unregistered_poetry_shape` structural exception, their verse shape is
malformed/unsupported, and they contribute no verse units and no substantive
coverage (see “Unsupported shapes” below).

### Shape: haiku — 3-line blocks

A haiku file is a sequence of **3-line blocks**, each block a complete verse
unit. Blocks are separated by one or more blank lines.

Fixture `haikus/HAI-0003` (shape as found in Filed content):

```md
---
id: haikus/HAI-0003
parent: haikus
title: Quiet morning
---

# Quiet morning

soft rain on the roof
the cat blinks, unbothered
steam rises, then falls

distant bells at noon
a paper cup left half full
wind folds the curtain

the kettle whistles
tea leaves settle in the cup
stillness, then one sip
```

Count: **3 complete haiku units** (each exactly 3 non-empty lines).

Malformed example (4 lines in one block):

```md
# Broken

one
two
three
four
```

Count: **0 complete, 1 malformed unit**.

### Shape: limerick — 5-line blocks

A limerick file is a sequence of **5-line blocks**, each block a complete
verse unit (the classic AABBA form, though the audit counts lines, not rhyme).

Fixture `limericks/LIM-0002`:

```md
---
id: limericks/LIM-0002
parent: limericks
title: The ledger
---

# The ledger

there once was a ledger so tall
it stood in the hall by the wall
it counted in threes
and hummed to the breeze
and balanced the books after all

the next one was short and quite wide
it kept every sum tucked inside
it tracked every cent
and never relented
then closed itself up for the night
```

Count: **2 complete limerick units** (each exactly 5 non-empty lines).

### Shape: aphorism — paragraph units

An aphorism file is a sequence of **paragraph units**, each paragraph a
complete non-empty verse unit. Paragraphs are separated by one or more blank
lines. A paragraph is one or more consecutive non-empty lines that are not
headings and not inside fences.

Fixture `aphorisms/APH-0004`:

```md
---
id: aphorisms/APH-0004
parent: aphorisms
title: Small truths
---

# Small truths

What is counted is kept.

What is kept is still counted.

A ledger forgets nothing and forgives nothing.
```

Count: **3 complete aphorism units**.

### Shape: placeholder (applies to any type)

A unit whose entire body matches a placeholder signature is counted in
`complete_count` (it is structurally present) **and** in
`placeholder_count`, and it contributes to `present_placeholder`, never to
`present_substantive`.

Signatures come from the policy `placeholder` block:

- `exact_lines`: a unit is placeholder when **every non-empty line** of the
  unit equals one of the exact lines (after optional case-insensitive
  comparison per `case_sensitive`).
- `title_prefixes`: when the record's `title` starts with one of the prefixes,
  all units in the record are treated as placeholder (the file is a stub).

Fixture `haikus/HAI-0101`:

```md
---
id: haikus/HAI-0101
parent: haikus
title: Stub: For 101
---

# Stub

Awaiting context
Awaiting context
Awaiting context
```

With `placeholder.exact_lines = ["Awaiting context"]` and
`placeholder.title_prefixes = ["Stub:"]`, this is **1 complete placeholder
unit, 0 substantive units**.

### Shape: empty record

A poetry record with no verse body at all (frontmatter only) has
**0 units** and classifies as `present_empty` for its owner.

Fixture `haikus/HAI-0102`:

```md
---
id: haikus/HAI-0102
parent: haikus
title: For 102
---

```

### Fenced code that must not be counted

```md
---
id: haikus/HAI-0200
parent: haikus
title: For 200
---

# For 200

real verse line one
real verse line two
real verse line three

```
awaiting context
awaiting context
awaiting context
```
```

Count: **1 complete unit** (the 3 real lines). The three fenced lines are
ignored and do not form a unit.

## Registry

| Poetry type | Shape | Unit definition |
| --- | --- | --- |
| `haiku` | 3-line blocks | exactly 3 non-empty lines per unit |
| `limerick` | 5-line blocks | exactly 5 non-empty lines per unit |
| `aphorism` | paragraph units | one or more non-empty non-heading lines between blanks |

## Unsupported shapes (single policy)

**A poetry type without a registered shape is never analyzed.** For every such
record the audit emits exactly one `unregistered_poetry_shape` structural
exception, classifies the record's verse shape as malformed/unsupported, does
not count any paragraph units, and grants no substantive coverage. There is no
fallback paragraph analysis for unknown types: the audit would rather fail the
structural gate than guess a shape.

Concretely, for an unregistered type:

- `exceptions` gains exactly one `{"kind": "unregistered_poetry_shape",
  "severity": "structural"}` for the record;
- the record's alignment is `malformed_record`;
- the record reports **zero complete verse units** and **one
  malformed/unsupported record**;
- per-record `malformed_units` is `1` and the aggregate `verse_totals` row
  counts the record (1 record) with `verse_units = 0`, `placeholder_units =
  0`, `substantive_units = 0`, `malformed_units = 1` — the per-record figure
  always sums to the aggregate;
- the alignment classification, the `totals.malformed_records` counter, the
  Markdown report, and the HTML report all agree on this single
  malformed/unsupported record;
- coverage for the owning source's expected type is `malformed`, never
  `present_substantive`;
- the record is **not** a paragraph unit source, so it cannot silently pass a
  `--fail-on=policy` gate by masquerading as substantive prose.

This is the only unsupported-shape policy: there is no separate “analyze as
paragraphs” fallback and no partial counting.

## Out of scope

Unsupported shapes are **not guessed**. A shape not listed above is reported
as `unregistered_poetry_shape` / malformed, never silently counted.
