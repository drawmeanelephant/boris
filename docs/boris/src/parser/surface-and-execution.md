---
title: "`src/parser.zig` surface and execution"
id: docs/boris/src/parser/surface-and-execution
parent: docs/boris/src/parser
status: draft
tags: [boris, zig, source-reference, surface, parser, frontmatter]
---

# `src/parser.zig` surface and execution

## Public API surface

### Types exported from `page.zig` and re-exported by `parser.zig`

| Symbol | Origin | Description |
| :-- | :-- | :-- |
| `max_title_bytes` | `page.zig` | 512 bytes — maximum UTF-8 bytes for a `title` value |
| `max_entity_id_bytes` | `page.zig` (via `identity.zig`) | 255 bytes — maximum bytes for an entity id |
| `max_tag_bytes` | `page.zig` | 64 bytes — maximum bytes for one tag token |
| `max_tag_count` | `page.zig` | 32 — maximum tags per document |
| `max_source_bytes` | `page.zig` | 1 MiB — maximum total source size accepted |
| `max_frontmatter_bytes` | `page.zig` | 64 KiB — maximum bytes inside the fences |
| `max_frontmatter_fields` | `page.zig` | 32 — maximum non-blank field lines |
| `Status` | `page.zig` | Closed enum: `draft`, `published`, `archived` |
| `FrontmatterView` | `page.zig` | Struct of source-view slices for all parsed fields |

### Types defined in `parser.zig`

| Symbol | Kind | Description |
| :-- | :-- | :-- |
| `Category` | `enum` | `EFRONTMATTER`, `EINVALIDUTF8`, `EINVALIDPATH` — stable diagnostic categories |
| `Diagnostic` | `struct` | `{ category, line: u32, column: u32, message: []const u8 }` |
| `ParsedDocument` | `struct` | `{ has_frontmatter, body, body_offset, meta: FrontmatterView }` |
| `ParseResult` | `struct` | `{ doc, diagnostic: ?Diagnostic }` plus `.isOk()` and `.category()` helpers |
| `parse` | `pub fn` | `(source: []const u8) ParseResult` — the single public entry point |


***

## Grammar specification (as implemented)

The parser enforces a bounded, line-oriented grammar. What follows is derived from the code, not from any separate specification document.

### Encoding and size gates (applied before any line scan)

Applied in order at the start of `parse`:

1. `source.len > max_source_bytes` → `EFRONTMATTER`, message: `"source exceeds maximum accepted size"`
2. UTF-8 BOM (`EF BB BF`) at byte 0 → `EINVALIDUTF8`, message: `"UTF-8 BOM is not allowed"`
3. `!std.unicode.utf8ValidateSlice(source)` (when `source.len > 0`) → `EINVALIDUTF8`, message: `"source is not valid UTF-8"`

### Frontmatter detection

- The opening fence must be the literal string `---` occupying the full first line, starting at column 0 with no leading whitespace.
- A file whose first line is not exactly `---` (e.g. starts with a space, or has any other content) is treated as having no frontmatter; the entire source becomes the body.
- An opening fence present but not followed by a newline is immediately `EFRONTMATTER` (`"unclosed frontmatter: missing closing ---"`).
- A closing fence is the first subsequent line that is exactly `---` at column 0. Any line that contains `---` with leading whitespace or trailing content does not close the frontmatter.
- If no closing fence is found before EOF, `EFRONTMATTER` (`"unclosed frontmatter: missing closing ---"`).
- The frontmatter block (bytes between opening and closing fences, exclusive) must be ≤ `max_frontmatter_bytes`; if not, `EFRONTMATTER` (`"frontmatter exceeds maximum size"`).


### Field line rules

After the opening fence, field lines are parsed one physical line at a time. Empty lines (after `trimAscii`) are skipped. The field counter increments only for non-empty lines; if it exceeds `max_frontmatter_fields`, `EFRONTMATTER`.

Each non-empty field line must satisfy:

- Not indented (first byte is not space or tab) — `EFRONTMATTER` (`"indented frontmatter lines are not supported"`).
- Not a YAML sequence item (`- ` or `- TAB` at column 0) — `EFRONTMATTER`.
- Not an anchor or alias (`&` or `*` at column 0) — `EFRONTMATTER`.
- Must contain a `:` — `EFRONTMATTER` (`"malformed frontmatter line (expected key: value)"`).
- Key (text before first `:`, after `trimAscii`) must be non-empty — `EFRONTMATTER` (`"empty frontmatter key"`).


### Accepted keys

The key set is closed. Any key not in the following list triggers `EFRONTMATTER` (`"unsupported frontmatter key"`):


| Key | Type | Constraint |
| :-- | :-- | :-- |
| `id` | plain or double-quoted scalar | ≤ `max_entity_id_bytes`; must pass `identity.validateEntityId` (else `EINVALIDPATH`) |
| `title` | plain or double-quoted scalar | ≤ `max_title_bytes` |
| `parent` | plain or double-quoted scalar | ≤ `max_entity_id_bytes`; must pass `identity.validateEntityId` (else `EFRONTMATTER` for parent, not `EINVALIDPATH`) |
| `status` | plain scalar | exactly `draft`, `published`, or `archived` |
| `tags` | flow-sequence form `[a, b, "c"]` | each token ≤ `max_tag_bytes`; ≤ `max_tag_count` items; no trailing comma |
| `relations` | flow-sequence form `[kind=target, …]` | ≤ `max_relation_count` (128); each target must pass `validateEntityId` (else `EINVALIDPATH`); kind matches the bounded open `RelationKind` token grammar |

All keys are de-duplicated; a second occurrence of any key is `EFRONTMATTER` (`"duplicate frontmatter key \"{key}\""`).

**Explicitly rejected legacy aliases:** `parentEntry` and `parent_entry` are both rejected as unsupported keys; they are not silently mapped to `parent`. This is directly tested.

### Scalar value rules (`parseScalarValue`)

- Empty (after trim) → `error.EmptyValue`
- Leading `|` or `>` → `error.BlockScalar`
- Leading `[` or `{` → `error.FlowCollection` (on non-`tags`/`relations` keys)
- Leading `&` or `*` → `error.AnchorAlias`
- Leading `'` → `error.SingleQuote`
- Double-quoted: must have matching closing `"` on the same line; inner content must contain no raw `"` characters; no escape sequences are recognized; empty inner content is `error.EmptyValue`
- Plain: returned as-is after `trimAscii`; a plain value may contain colons (demonstrated by the `"title may contain colons"` test)


### Tag list rules (`parseTagsList`)

Accepted form: `[item, item, "item"]`. Each item is parsed as a scalar. Single-quoted tokens within the list are `error.BadTags`. A trailing comma (e.g. `[alpha,]` or `[alpha, \t]`) is `error.BadTags`. Empty list `[]` is accepted and yields `tag_count = 0`.

### Relations list rules (`parseRelationsList`)

Accepted form: `[kind=target, kind=target]`. Each entry must be `kind=target` where `=` is the sole separator. Multiple `=` signs, missing target, missing kind, or trailing comma are `error.BadRelations`. An unknown kind string is `error.UnknownKind`. A target failing `validateEntityId` is `error.InvalidTarget` → `EINVALIDPATH`. Duplicate `(kind, target)` tuples are `error.DuplicateRelation`.

### Line ending behavior

- LF and CRLF are both accepted for fence and field lines; `readPhysicalLine` strips the trailing `\r` only when paired with a following `\n`.
- An isolated CR is not a line break; it remains part of line content. This means `---\r` at EOF (without a following `\n`) does not constitute a closing fence — verified by the `"bare CR at EOF does not close frontmatter"` test.
- Body bytes are returned verbatim; the parser performs no line-ending rewrite on the body.


### Body and offset

On success with frontmatter, `doc.body` is `source[close_after..]` where `close_after` is the byte position immediately following the closing fence's newline (or EOF if the fence has no newline). `doc.body_offset` is `close_after`. All returned string slices are views into `source`.

***

## Ownership contract

This is the most critical correctness invariant in the file.

The parser allocates nothing. All `[]const u8` fields in `ParsedDocument` and `FrontmatterView` are slices into the caller's `source` buffer. The `message` field in `Diagnostic` is always a static string literal (never allocator-owned). Callers that store parsed metadata beyond the lifetime of the source buffer (e.g. `PageDb.promote`) must explicitly `dupe` every string field onto a long-lived arena before freeing the source buffer.

This contract is:

- **Documented** in the `parser.zig` module doc comment and in `page.zig`'s `FrontmatterView` comment.
- **Mechanically enforced** by `PageDb.promote` in `page.zig`, which dupes all strings onto the retain arena.
- **Demonstrated by test** in `page.zig`'s `"PageDb.promote owns strings after source buffer free"` test, which explicitly frees the source buffer after promotion and verifies that promoted strings remain valid.
- **Not enforced by the type system**: Zig does not prevent a caller from reading a dangling slice. The contract is documentation- and convention-enforced at the ABI layer between `parser.zig` and its callers.

***

## Diagnostic model

### `Category` enum

```text
EFRONTMATTER   — unclosed fence, bad line, unknown/duplicate key,
                 unsupported form, empty/oversize values,
                 invalid status/tags, source/frontmatter limits
EINVALIDUTF8   — invalid UTF-8 bytes in source or leading BOM
EINVALIDPATH   — frontmatter `id` or relation target fails entity-id shape rules
```

`Category.name()` returns the string form of the tag (e.g. `"EFRONTMATTER"`). This is directly tested in `"Category.name matches contract strings"`.

### `Diagnostic` fields

- `category`: one of the three `Category` variants
- `line`: 1-based line number within `source`; `1` when not applicable
- `column`: 1-based byte column within the line; `1` when not applicable or when computed by `keyColumnInLine` fails to find the key
- `message`: static `[]const u8` string literal — never heap-allocated

Fail-fast behavior: the first diagnostic encountered terminates the parse and is returned. Partial field state may be written to `doc.meta` before the failure; callers must not rely on partial results when `diagnostic != null`.

***

## Internal helper inventory

| Symbol | Kind | Description |
| :-- | :-- | :-- |
| `trimAscii(s)` | private fn | `std.mem.trim(u8, s, " \t")` |
| `isSpace(c)` | private fn | True for space and tab |
| `readPhysicalLine(source, start)` | private fn | Returns `(line_without_trailing_CR, next_offset, saw_newline)` |
| `keyColumnInLine(line, key)` | private fn | 1-based byte column of first occurrence of `key` in `line`, or `1` |
| `fail(category, line, column, message)` | private fn | Constructs a `ParseResult` with `diagnostic` set |
| `utf8BomAtStart(source)` | private fn | True when first 3 bytes are `EF BB BF` |
| `parseScalarValue(raw)` | private fn | Parses one-line scalar; returns `ScalarError` on rejection |
| `parseTagsList(raw, out)` | private fn | Parses `[a, b, "c"]` into fixed-size output array |
| `parseRelationsList(raw, out)` | private fn | Parses `[kind=target, …]` into fixed-size output array |
| `readFixture(allocator, rel)` | test-only fn | Opens and reads a fixture file relative to cwd |
| `expectFixtureCategory(rel, expected)` | test-only fn | Asserts that a named fixture yields a specific error category |


***
