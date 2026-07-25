---
title: "`src/parser.zig` evidence and cases"
id: docs/boris/src/parser/evidence-and-cases
parent: docs/boris/src/parser
status: draft
tags: [boris, zig, source-reference, evidence, parser, frontmatter]
---

# `src/parser.zig` evidence and cases

## Test inventory

### Inline unit tests

| Test name | Kind | What it asserts |
| :-- | :-- | :-- |
| `parse: valid no-frontmatter document` | positive | No frontmatter detected; `body == source`; all meta fields null/zero |
| `parse: empty file is valid no-frontmatter` | positive | Empty input succeeds; body is empty string |
| `parse: valid frontmatter document` | positive | All six keys parsed; string fields are views into `src` (pointer arithmetic verified); body starts after closing fence |
| `parse: bounded semantic relations` | positive | Two-element relations list with correct `kind` and `target` values |
| `parse: semantic relation malformed, unknown, duplicate, and invalid target` | negative (table) | Six hostile relation strings; verifies `EFRONTMATTER` for five and `EINVALIDPATH` for `../old` target |
| `parse: canonical parent is accepted` | positive | `parent: guides/intro` accepted; stored as source view |
| `parse: CRLF input` | positive | CRLF fences and field lines stripped correctly; body begins at `# Body\r\n` |
| `parse: bare CR at EOF does not close frontmatter` | negative | `---\r` at EOF is not a closing fence; `EFRONTMATTER` with `"unclosed"` in message |
| `parse: BOM rejected as EINVALIDUTF8` | negative | `\xEF\xBB\xBF` prefix triggers `EINVALIDUTF8`; exact message checked |
| `parse: unclosed fence is EFRONTMATTER` | negative | No closing `---` line; `EFRONTMATTER` with `"unclosed"` in message |
| `parse: duplicate key is EFRONTMATTER` | negative | Second `title:` line; `EFRONTMATTER` with `"duplicate"` in message |
| `parse: unknown key is EFRONTMATTER` | negative | `category: docs`; `EFRONTMATTER` with `"unsupported"` in message |
| `parse: legacy parentEntry is unknown key` | negative | `parentEntry:` rejected; `parent` remains null |
| `parse: legacy parent_entry is unknown key` | negative | `parent_entry:` rejected; `parent` remains null |
| `parse: nested mapping is EFRONTMATTER` | negative | Indented line after `title:`; `EFRONTMATTER` |
| `parse: invalid tags syntax is EFRONTMATTER` | negative | `tags: not-a-list`; `EFRONTMATTER` with `"tags"` in message |
| `parse: tags reject trailing commas` | negative (table) | `[alpha,]` and `[alpha, \t]`; both `EFRONTMATTER` |
| `parse: overlong title is EFRONTMATTER` | negative, heap | Title of `max_title_bytes + 1`; `EFRONTMATTER` with `"title"` in message |
| `parse: overlong frontmatter block is EFRONTMATTER` | negative, heap | Block of `max_frontmatter_bytes + 1` bytes; `EFRONTMATTER` with `"frontmatter exceeds"` in message |
| `parse: overlong source is EFRONTMATTER` | negative, heap | `max_source_bytes + 1` bytes; `EFRONTMATTER` with `"source exceeds"` in message |
| `parse: invalid UTF-8 is EINVALIDUTF8` | negative | `\xff` byte in body region (after fences but before scan); detected in pre-scan UTF-8 gate |
| `parse: body-start boundary after closing fence` | positive | `body_offset` equals `src.len - 4` for `"BODY"` suffix; `body == "BODY"` |
| `parse: empty frontmatter yields empty body offset after fences` | positive | `---\n---\n# hi\n`; frontmatter present; body is `"# hi\n"` |
| `parse: leading space means no frontmatter` | positive | ` ---` (leading space) is not an opening fence; entire file is body |
| `parse: invalid path id is EINVALIDPATH` | negative | `id: ../escape`; `EINVALIDPATH` |
| `parse: double-quoted title strips quotes; no escapes` | positive | `"Hello World"` → `Hello World` |
| `parse: single-quoted value rejected` | negative | `'nope'` → `EFRONTMATTER` |
| `parse: title may contain colons` | positive | `Foo: Bar` parsed correctly as title (colon in value) |
| `parse: empty tags list` | positive | `tags: []` → `tag_count == 0`, success |
| `parse: tag too long is EFRONTMATTER` | negative, heap | Tag of `max_tag_bytes + 1`; `EFRONTMATTER` with `"tag"` in message |
| `parse: accepts title and id at exact length limits` | positive, heap | Title of exactly `max_title_bytes` and id of exactly `max_entity_id_bytes`; both accepted |
| `Category.name matches contract strings` | unit | `@tagName` round-trip for all three `Category` variants |

### Fixture-driven tests

| Test name | Fixture path | Expected outcome |
| :-- | :-- | :-- |
| `fixture: valid empty-no-fm` | `fixtures/content/valid/empty-no-fm.md` | `isOk()`, no frontmatter, body == raw |
| `fixture: valid trunk-root` | `fixtures/content/valid/trunk-root.md` | `id == "home"`, `title == "Home Trunk"`, `status == .published`, 1 tag `"home"` |
| `fixture: valid satellite-child` | `fixtures/content/valid/satellite-child.md` | `parent == "home"`, `title == "Child Satellite"`, `status == .draft` |
| `fixture: valid nested deep page` | `fixtures/content/valid/nested/deep/page.md` | `title == "Nested Deep Page"`, `id == null`, `parent == null` |
| `fixture: invalid duplicate-key → EFRONTMATTER` | `fixtures/content/invalid/duplicate-key.md` | `!isOk()`, `EFRONTMATTER` |
| `fixture: invalid unclosed-frontmatter → EFRONTMATTER` | `fixtures/content/invalid/unclosed-frontmatter.md` | `!isOk()`, `EFRONTMATTER` |
| `fixture: invalid nested-mapping → EFRONTMATTER` | `fixtures/content/invalid/nested-mapping.md` | `!isOk()`, `EFRONTMATTER` |
| `fixture: invalid invalid-utf8 → EINVALIDUTF8` | `fixtures/content/invalid/invalid-utf8.md` | `!isOk()`, `EINVALIDUTF8` |
| `fixture: invalid invalid-path-id → EINVALIDPATH` | `fixtures/content/invalid/invalid-path-id.md` | `!isOk()`, `EINVALIDPATH` |
| `fixture: graph-invalid files still parse (not parser errors)` | 9 files under `fixtures/content/invalid/` | All `isOk()` — graph errors are not parser errors |


***

## Correctness and boundary analysis

### Boundary cases with direct test coverage

- **Exact-limit acceptance**: title at exactly `max_title_bytes` and id at exactly `max_entity_id_bytes` are accepted; one byte over is rejected. This is directly demonstrated.
- **Off-by-one on source size**: `max_source_bytes + 1` is rejected; the exact limit is not tested for acceptance at the source level (no test constructs a source of exactly `max_source_bytes` and verifies success). This is a minor gap but the limit is applied first, before any scan.
- **CRLF at fence boundaries**: the `readPhysicalLine` function strips the trailing `\r` only when a `\n` follows; an isolated `\r` is not a line break. Verified by two tests.
- **Body offset arithmetic**: `body_offset` is verified by pointer comparison and by the explicit `"body-start boundary after closing fence"` test.
- **Source-view pointer provenance**: the `"valid frontmatter document"` test explicitly checks that `title.ptr` and `body.ptr` lie within the `src` buffer via `@intFromPtr` comparison. This is the only direct pointer-provenance assertion.


### Known gaps and uncertainties

- **`EINVALIDPATH` vs `EFRONTMATTER` for `parent:`**: The code emits `EFRONTMATTER` (not `EINVALIDPATH`) when `parent:` fails `validateEntityId`. The `id:` key emits `EINVALIDPATH`. Whether this asymmetry is intentional is documented by behavior but not by an explicit contract comment. No test directly verifies that a bad-path `parent:` value yields `EFRONTMATTER` rather than `EINVALIDPATH`.
- **Column accuracy for multi-colon lines**: `keyColumnInLine` returns the byte offset of the first occurrence of the key string in the raw line. For keys that also appear as substrings in the value (e.g. `title: title`), the column returned is that of the key occurrence, which is correct. However, this function is not independently tested.
- **`message` field stability across builds**: Messages are static string literals. No contract document explicitly lists them as stable API; they are tested by substring match (`std.mem.indexOf`) in many tests, not by equality. Renaming or rewording a message would not break the contract as defined, but would break the substring-match tests.
- **Allocator use in overlong tests**: three tests (`overlong title`, `overlong frontmatter block`, `overlong source`) use `std.testing.allocator` (a leak-detecting GPA). If the parser were to allocate (which it does not), these tests would catch a leak. The allocation is only for constructing the adversarial input buffer.
- **UTF-8 validation scope**: `utf8ValidateSlice` is applied to the entire source, including the body. The test `"parse: invalid UTF-8 is EINVALIDUTF8"` places the invalid byte in the body region (after the closing fence). This means an invalid byte anywhere in the file, even in the body, will be caught by the pre-scan gate. This behavior is consistent with the module comment but is not separately documented as a design decision.
- **Fixture files are not committed in the inspected read**: the fixture directory was not directly read during this analysis. The fixture file paths and expected behaviors are derived exclusively from the test code. Whether the fixtures on disk exactly match the test expectations is not independently verified here.

***

## Control flow

```text
parse(source)
    │
    ├─ [source too large]          → EFRONTMATTER
    ├─ [BOM at start]              → EINVALIDUTF8
    ├─ [invalid UTF-8 anywhere]    → EINVALIDUTF8
    ├─ [empty source]              → ok, no frontmatter, body = ""
    │
    ├─ readPhysicalLine(source, 0)
    │   ├─ [first line != "---"]   → ok, no frontmatter, body = source
    │   └─ [first line == "---", no newline]  → EFRONTMATTER (unclosed)
    │
    ├─ scan for closing fence
    │   └─ [no closing fence]      → EFRONTMATTER (unclosed)
    │
    ├─ [fm_block.len > max_frontmatter_bytes]  → EFRONTMATTER
    │
    └─ field line loop
        │
        ├─ [empty line]            → skip
        ├─ [indented line]         → EFRONTMATTER
        ├─ [YAML sequence item]    → EFRONTMATTER
        ├─ [anchor/alias]          → EFRONTMATTER
        ├─ [no colon]              → EFRONTMATTER
        ├─ [empty key]             → EFRONTMATTER
        ├─ [field_count > max]     → EFRONTMATTER
        │
        ├─ key == "tags"
        │   ├─ [duplicate]         → EFRONTMATTER
        │   └─ parseTagsList       → ok or EFRONTMATTER
        │
        ├─ key == "relations"
        │   ├─ [duplicate]         → EFRONTMATTER
        │   └─ parseRelationsList  → ok, EFRONTMATTER, or EINVALIDPATH
        │
        ├─ parseScalarValue(raw_val)
        │   └─ [error]             → EFRONTMATTER
        │
        ├─ key == "title"          → ok or EFRONTMATTER (dup/overlong)
        ├─ key == "id"             → ok, EFRONTMATTER (dup/overlong),
        │                            or EINVALIDPATH (bad path shape)
        ├─ key == "parent"         → ok or EFRONTMATTER (dup/overlong/bad path)
        ├─ key == "status"         → ok or EFRONTMATTER (dup/bad value)
        └─ [any other key]         → EFRONTMATTER (unsupported)
```


***
