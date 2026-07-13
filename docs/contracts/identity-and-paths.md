# Identity and paths (v0.1)

**Status:** normative contract for future compiler implementation  
**Milestone:** 2 (contracts + fixtures). Discovery / path canonicalization is
**not** implemented on the default CLI yet.

---

## Definitions

| Term | Meaning |
|------|---------|
| **content root** | Directory whose files are discovered (default: `content/`) |
| **source path** | Path of a page file relative to the content root |
| **entity id** / **id** | Stable entity identity used as graph key and IR primary key |
| **output-relative path** | Path under an output root (e.g. `.boris/`, future `dist/`, RAG) derived only from validated ids |

IDs and output-relative paths use **`/`** as the sole path separator.

---

## Discovery (planned compiler behavior)

1. Recursively walk the content root (real directories only).
2. Include only regular files whose names end with an accepted page extension
   (see Extension policy).
3. Ignore all other files (assets, `README.MD` with wrong case, non-page names).
4. Symlink policy for v0.1 (when implemented): reject symlinked directories and
   page files; do not follow directory symlinks. Exact diagnostic codes for
   symlink-only failures may be added later; path shape failures use
   [`EINVALIDPATH`](diagnostics.md).

---

## Extension policy (explicit)

| Suffix | Accepted as page? |
|--------|-------------------|
| `.md`  | **yes** (case-sensitive) |
| `.mdx` | **yes** (case-sensitive) |
| `.MD`, `.Md`, `.MDX`, `.Mdx`, … | **no** |
| other  | **no** |

**Case behavior is case-sensitive for extensions.** Only lowercase `.md` and
`.mdx` are page sources. Implementations must **not** case-fold extensions.

Exactly one trailing extension is stripped for ID derivation
(`my.notes.md` → id `my.notes`; intermediate dots stay).

---

## Source path canonical form

After discovery, each file has a **source path** string `sourcePath` such that:

1. Relative to content root (no content-root prefix).
2. Uses `/` as the sole separator (never `\`).
3. Does **not** start with `/` or `./`.
4. Does **not** contain empty segments (`//`), `.` segments, or `..` segments.
5. Does **not** end with `/`.
6. Preserves the path’s Unicode and letter case exactly as stored on disk
   (after separator normalization). Comparison is **case-sensitive**.
7. Ends with a case-sensitive page extension (`.md` or `.mdx`).

**Invalid** examples (must not appear as `sourcePath`; emit
[`EINVALIDPATH`](diagnostics.md)):

```text
../outside.md
/abs/path.md
guides//intro.md
guides/./intro.md
guides\intro.md
```

---

## ID derivation

```text
id = sourcePath with trailing ".md" or ".mdx" removed
     (after canonicalize: '\' → '/', reject absolute / . / .. / empty segments)
```

Letter case is **preserved**. Platform separators must not leak into graph keys.

| sourcePath | id |
|------------|-----|
| `index.md` | `index` |
| `guides/intro.md` | `guides/intro` |
| `Guides/Intro.md` | `Guides/Intro` |
| `nested/deep/page.md` | `nested/deep/page` |
| `a\b\c.md` (pre-normalize) | `a/b/c` |

### Rules

1. Single shared derivation function for all pages.
2. Entity ids **never** start with `/`, **never** contain `\`, and **never**
   contain empty, `.`, or `..` segments.
3. Entity id length ≤ 255 UTF-8 bytes.
4. Empty ID is forbidden (e.g. a file named only `.md` is invalid).
5. ID uniqueness across the content root is **byte-exact** →
   [`EDUPLICATEID`](diagnostics.md).
6. Do **not** silently lowercase ids.
7. Frontmatter `id:` overrides path-derived id but must satisfy the **same**
   shape rules; violations → [`EINVALIDPATH`](diagnostics.md) (or
   [`EFRONTMATTER`](diagnostics.md) for empty/oversize values — prefer
   `EINVALIDPATH` when the value is a path/id shape violation).

### Slash normalization demonstration

A nested source path such as `nested/deep/page.md` yields canonical id
`nested/deep/page` (forward slashes only, no leading/trailing slash, no empty
segments). Fixture: `fixtures/content/valid/nested/deep/page.md`.

---

## Output-relative paths

HTML, RAG, and other outputs (when implemented) construct paths **only** from
validated entity ids:

| Consumer | Relative path (planned) |
|----------|-------------------------|
| HTML (`dist/`) | `{entity_id}.html` |
| RAG corpus | `content/pages/{entity_id}.md` |
| IR | under `.boris/` (not path-from-id for the three JSON files) |

Because entity ids cannot contain `..`, empty, or absolute segments, joining
under an output root must not escape that root. Callers must not concatenate
raw, unvalidated source paths into output locations.

---

## Uniqueness and collision

| Situation | Code |
|-----------|------|
| Same entity id bytes (two paths or `id:` overrides) | [`EDUPLICATEID`](diagnostics.md) |
| Illegal / absolute / traversal path or id | [`EINVALIDPATH`](diagnostics.md) |

---

## Deterministic ordering

Discovery may visit files in any order. **Before all later processing**
(frontmatter parse, graph resolve, emit):

- Sort discovered page records by **`id`** ascending (bytewise UTF-8), with
  **`sourcePath`** as a stable tie-breaker.

Never depend on filesystem enumeration order. See [ir-schema.md](ir-schema.md).

---

## Non-goals (v0.1)

- No slug maps or alias tables
- No automatic `index.md` → bare-directory URL rewriting
- No following of content-tree symlinks (reject when implemented)
- No watch mode / concurrent discovery
- No case-insensitive extension matching
