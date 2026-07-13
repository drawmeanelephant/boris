# Frontmatter grammar (v0.1)

**Status:** normative contract for future compiler implementation  
**Milestone:** 2 (contracts + fixtures). Parsing is **not** implemented on the
default CLI yet.

Boris frontmatter is a **deliberately closed, bounded grammar**. It is **not**
general YAML. Implementations must not grow into a YAML 1.1/1.2 subset by
accident.

---

## Encoding

1. Source must be **valid UTF-8** before any frontmatter or body handling.
2. A UTF-8 **BOM** (`EF BB BF`) is **rejected** (never stripped) →
   [`EINVALIDUTF8`](diagnostics.md).
3. Invalid UTF-8 sequences anywhere in the file → [`EINVALIDUTF8`](diagnostics.md).
4. Line endings: **LF** and **CRLF** are accepted. Isolated CR without LF is
   treated as part of the line content (not a line break).

---

## Presence and fences

Frontmatter is **optional**.

- Recognized **only** when an opening fence is a **complete first line** of the
  file: exactly `---` at **byte zero / column zero** (optional trailing `\r`
  before the line’s `\n`).
- Files that do not begin that way have **no** frontmatter; the entire file is
  body (`bodyOffset` = `0`).
- A leading space (or any non-fence first line) means “no frontmatter” — **not**
  an error.
- Closing fence: a complete line that is exactly `---` at column zero
  (optional trailing `\r`).
- Body begins at the first byte after the closing fence’s newline.
- Missing closing fence ⇒ unclosed frontmatter → [`EFRONTMATTER`](diagnostics.md).
- Empty frontmatter (open + immediate close) is valid; fields default as below.

```text
---
<zero or more field lines>
---
<body bytes…>
```

---

## Field lines

Each non-empty line inside the fences is a **field**:

```text
key: value
```

Informal grammar:

```text
field      := key ":" [ " " | "\t" ]* value-part
key        := <non-empty token without leading indent>
value-part := plain | dquoted | tags-list   ; tags-list only for key "tags"
plain      := <non-empty run; leading/trailing space/tab trimmed>
dquoted    := '"' <chars without raw "> '"'
tags-list  := "[" [ tag-item ( "," tag-item )* ] "]"
tag-item   := plain-token | dquoted
```

### Rules

1. **One-line scalars only.** No multiline values, no continuation lines.
2. **First `:` on the line** separates key from value. Further `:` characters
   belong to the plain value (`title: Foo: Bar` → value `Foo: Bar`).
3. Keys are **case-sensitive**.
4. Empty or whitespace-only lines are skipped.
5. Lines without `:` ⇒ malformed field → [`EFRONTMATTER`](diagnostics.md).
6. Lines with leading space/tab ⇒ nested mapping form ⇒ **unsupported** →
   [`EFRONTMATTER`](diagnostics.md).
7. Lines starting with `- ` ⇒ YAML sequence form ⇒ **unsupported**.
8. Inline comments (`# …`) are **not** supported; `#` is ordinary value text.
9. **Duplicate keys** (same recognized key twice) ⇒ hard error →
   [`EFRONTMATTER`](diagnostics.md) (subcategory: duplicate key).
10. **Unknown keys** ⇒ hard error → [`EFRONTMATTER`](diagnostics.md). The key
    set is closed; no silent “extras for forward compatibility.”

### Quoted values

| Form | Behavior |
|------|----------|
| Plain | Trim leading/trailing ASCII space/tab; must be non-empty after trim |
| Double-quoted `"…"` | Surrounding `"` stripped; **no** escape sequences; embedded raw `"` illegal; empty `""` illegal |
| Single-quoted `'…'` | **Rejected** (do not partially parse) |

### Explicitly rejected YAML-looking forms

Do **not** half-parse these; emit [`EFRONTMATTER`](diagnostics.md):

- Nested mappings (indented keys)
- Block scalars (`|` and `>` as the value)
- Anchors / aliases (`&name`, `*name`)
- Flow mappings `{ … }`
- Flow sequences `[ … ]` on any key **except** the deliberately supported
  `tags: [ … ]` form
- Multiline scalar forms
- Multiple documents mid-file

---

## Canonical author-facing keys (closed set)

Exactly these five keys are accepted. **No aliases.**

| Key | Required | Value | Notes |
|-----|----------|-------|-------|
| `id` | no | plain/dquoted entity id | Override path-derived id; shape rules in [identity-and-paths.md](identity-and-paths.md) |
| `title` | no | plain/dquoted string | ≤512 UTF-8 bytes |
| `parent` | no | plain/dquoted entity id | Foreign key to a **Trunk** entity id; ≤255 bytes |
| `status` | no | `draft` \| `published` \| `archived` | Exact spellings only |
| `tags` | no | `[a, b, "c"]` only | Bracket list; plain or double-quoted items |

### Forbidden key names and forms

Implementations **must not** accept or silently map:

| Forbidden | Reason |
|-----------|--------|
| `parentEntry` | Legacy alias — **not** part of v0.1 compiler grammar |
| `parent_entry` | Legacy alias — **not** part of v0.1 compiler grammar |
| `aliases` | Out of scope |
| YAML anchors / aliases | Out of scope |
| Multiline scalars | Out of scope |
| Nested objects / mappings | Out of scope |
| Arbitrary extra keys | Closed set only |

If content uses `parentEntry` or `parent_entry`, the compiler treats them as
**unknown keys** → [`EFRONTMATTER`](diagnostics.md).

---

## Role of `parent` (field-level)

| Condition | Role after resolution |
|-----------|------------------------|
| `parent` omitted or null | **Trunk** |
| `parent` present (non-empty entity id) | **Satellite** |

Further graph rules (missing parent, self-parent, satellite-of-satellite,
cycles, duplicate ids) are specified in [ir-schema.md](ir-schema.md) and
diagnostics in [diagnostics.md](diagnostics.md).

A **Trunk** has no `parent` field (or omits it).  
A **Satellite** has **exactly one** `parent` naming a Trunk entity id.

---

## Defaults when frontmatter is absent or a key is omitted

| Field | Default |
|-------|---------|
| `title` | `null` (no derived title from filename in v0.1) |
| `parent` | `null` → page is a **Trunk** |
| `id` | path-derived entity id ([identity-and-paths.md](identity-and-paths.md)) |
| `status` | `null` (unset) |
| `tags` | empty list |

### Empty page with no frontmatter

Allowed. Example: a file whose entire contents are empty, or only body text
with no opening `---` fence.

| Property | Expected |
|----------|----------|
| Frontmatter | absent |
| `bodyOffset` | `0` |
| `id` | path-derived (e.g. `empty-no-fm.md` → `empty-no-fm`) |
| `title` | `null` |
| `parent` | `null` |
| `role` | `trunk` |
| `status` | `null` |
| `tags` | `[]` |

---

## Body

Everything after the closing fence (or the entire file if no frontmatter) is
**opaque body bytes** for the metadata / IR stage. Markdown AST, Apex render,
and component tokenization (`<Aside>`) are **out of scope** for the v0.1 IR
compiler surface.

---

## Limits (normative bounds)

| Limit | Bound | On overflow |
|-------|------:|-------------|
| Title bytes | 512 | value rejected → [`EFRONTMATTER`](diagnostics.md) |
| Entity id / parent / id bytes | 255 | value rejected → [`EFRONTMATTER`](diagnostics.md) or [`EINVALIDPATH`](diagnostics.md) for id shape |
| Frontmatter block bytes | 64 KiB | → [`EFRONTMATTER`](diagnostics.md) |
| Frontmatter field count | 32 | → [`EFRONTMATTER`](diagnostics.md) |

---

## Examples

Valid:

```markdown
---
id: guides/intro
title: Introduction
status: published
tags: [guide, intro]
---

# Body starts here
```

Valid satellite:

```markdown
---
title: Intro Tips
parent: guides/intro
---
```

Valid (no frontmatter):

```markdown
# Just a page
```

Invalid (unknown key):

```markdown
---
title: X
category: docs
---
```

Invalid (nested mapping):

```markdown
---
title:
  en: Hello
---
```

Invalid (legacy parent alias — unknown key):

```markdown
---
parentEntry: guides/intro
---
```

---

## Explicit non-support

- YAML 1.1 / 1.2 parsers
- Nested keys, multi-line strings, multiple documents mid-file
- Arbitrary extra keys for forward compatibility
- Escape sequences inside double quotes
- Single-quoted scalars
- `parentEntry` / `parent_entry` aliases
- Full Markdown / MDX / executable component frontmatter
