# Identity and paths (v0.1)

**Status:** normative contract; **implemented** for path/id derivation and
discovery in milestone 4 (`src/identity.zig`, `src/scanner.zig`).  
Default CLI still stubs the full content pipeline (does not scan on every run
until later milestones wire it).

See also: [scanner.md](scanner.md).

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

## Discovery

Implemented by [`src/scanner.zig`](../../src/scanner.zig). Normative walk
behavior is in [scanner.md](scanner.md). Summary:

1. Recursively walk the content root (real directories only).
2. Include only regular files whose names end with an accepted page extension
   (see Extension policy).
3. Ignore all other files (assets, `README.MD` with wrong case, non-page names).
4. **Symlink policy:** reject symlinked directories and page files; do **not**
   follow directory symlinks. Path shape failures use
   [`EINVALIDPATH`](diagnostics.md) when surfaced as content diagnostics;
   the scanner may also fail the walk with `SymlinkRejected` / `InvalidPath`.

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
(`my.notes.md` → id `my.notes`; intermediate dots stay). Prefer matching
`.mdx` before `.md` so a file ending in `.mdx` is not treated as `.md`.

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

A single leading `./` or `.\` may be stripped during canonicalize; other `.`
segments are illegal (never silently folded).

---

## ID derivation

**Single function (implementation):** `identity.canonicalEntityId` in
[`src/identity.zig`](../../src/identity.zig).

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

1. Single shared derivation function for all pages (`canonicalEntityId` only).
2. Entity ids **never** start with `/`, **never** contain `\`, and **never**
   contain empty, `.`, or `..` segments.
3. Entity id length ≤ 255 UTF-8 bytes.
4. Empty ID is forbidden (e.g. a file named only `.md` is invalid).
5. ID uniqueness across the content root is **byte-exact** →
   [`EDUPLICATEID`](diagnostics.md). Discovery **keeps** all colliding pages
   so the graph stage can name both sources.
6. Do **not** silently lowercase ids.
7. Frontmatter `id:` overrides path-derived id but must satisfy the **same**
   shape rules; violations → [`EINVALIDPATH`](diagnostics.md) (or
   [`EFRONTMATTER`](diagnostics.md) for empty/oversize values — prefer
   `EINVALIDPATH` when the value is a path/id shape violation). *(Override is
   not applied at milestone 4 discovery; path-derived id only.)*

### Slash normalization demonstration

A nested source path such as `nested/deep/page.md` yields canonical id
`nested/deep/page` (forward slashes only, no leading/trailing slash, no empty
segments). Fixture: `fixtures/content/valid/nested/deep/page.md`.

---

## Output-relative paths

Outputs construct paths **only** from validated entity ids via
`identity.safeOutputRelativePath` (HTML: `{entity_id}.html`) or
`identity.ragPagePath` when RAG is wired:

| Consumer | Relative path |
|----------|----------------|
| HTML (`dist/`) / scan default | `{entity_id}.html` |
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

- Sort discovered page records by **`entity_id`** ascending (bytewise UTF-8),
  with **`source_path`** as a stable tie-breaker.

Never depend on filesystem enumeration order. See [ir-schema.md](ir-schema.md)
and [scanner.md](scanner.md).

---

## Non-goals (v0.1)

- No slug maps or alias tables
- No automatic `index.md` → bare-directory URL rewriting
- No following of content-tree symlinks
- No watch mode / concurrent discovery
- No case-insensitive extension matching
