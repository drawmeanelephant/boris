# Content scanner (discovery)

**Status:** normative for milestone 4 implementation  
**Module:** [`src/scanner.zig`](../../src/scanner.zig)  
**Identity:** [`src/identity.zig`](../../src/identity.zig) — single `canonicalEntityId`  
**Related:** [identity-and-paths.md](identity-and-paths.md)

---

## Goals

- Deterministic recursive discovery of page files under a content root
- Logical path metadata independent of host absolute paths
- One centralized identity derivation function
- Safe output-relative paths that cannot escape an output root
- Explicit symlink policy (no following directory symlinks)

---

## Inputs

| Input | Meaning |
|-------|---------|
| `content_root` | Directory to walk (CLI `--input`, default `content`) |
| long-lived retain allocator | Owns all strings on discovered records |
| list allocator | Owns the flat list spine and temporary walk state |

No configuration files. No environment variables. No frontmatter parse at this stage.

---

## Discovery algorithm

1. Open `content_root` with iterate capability (missing → `ContentDirMissing` / I/O).
2. Walk recursively with **selective** entry (real directories only).
3. For each directory entry:
   - **Symlink** → reject (`SymlinkRejected`); do **not** enter.
   - **Directory** → enter once per filesystem inode; re-visit → `SymlinkCycle`.
   - **Regular file** → accept only if basename ends with case-sensitive `.md` or `.mdx`.
   - Other kinds / extensions → ignore (including `.txt`, `.MD`, `.MDX`).
4. For each accepted file, build a `Page` record (see Record shape).
5. **Sort** the flat list before any caller processes it.

---

## Extension policy

| Suffix | Accepted? |
|--------|-----------|
| `.md`  | **yes** (case-sensitive) |
| `.mdx` | **yes** (case-sensitive) |

### Reserved fragment tree

The content-root directory **`includes/`** is **not** entered during discovery.
Files under `content/includes/**` are available to Boris-mediated
`{{include path}}` expansion but are never pages (no entity id, no HTML
output). Nested directories named `includes` under other paths (e.g.
`guides/includes/`) are **not** reserved and remain normal page trees.
See [includes-and-wiki-links.md](includes-and-wiki-links.md).
| `.MD`, `.Md`, `.MDX`, `.Mdx`, … | **no** (ignored) |
| `.txt` and all other | **no** (ignored) |

---

## Record shape (`Page`)

Flat collection only. Each record minimally includes:

| Field | Logical meaning | Owner |
|-------|-----------------|-------|
| `source_path` | Content-root-relative path, `/` only | retain allocator |
| `entity_id` | From `identity.canonicalEntityId` | retain allocator |
| `output_path` | From `identity.safeOutputRelativePath` | retain allocator |
| `kind` | `.md` or `.mdx` | value type |

**Openable source strategy:** open the content root as `Io.Dir`, then open
`source_path` relative to that handle. Logical metadata never stores host
absolute paths.

There is no document-local arena at discovery.

---

## Sort key

Before any later processing:

1. **`entity_id`** ascending (bytewise UTF-8)
2. **`source_path`** ascending as a stable tie-breaker

Never depend on filesystem enumeration order.

---

## Identity derivation

**Exactly one function:** `identity.canonicalEntityId(allocator, source_path)`.

```text
canonical source path  →  strip one trailing ".md" | ".mdx"  →  entity id
```

Examples:

| source_path | entity_id | output_path |
|-------------|-----------|-------------|
| `index.md` | `index` | `index.html` |
| `guides/intro.md` | `guides/intro` | `guides/intro.html` |
| `nested/deep/page.md` | `nested/deep/page` | `nested/deep/page.html` |
| `Guides/Intro.md` | `Guides/Intro` | `Guides/Intro.html` |
| `my.notes.md` | `my.notes` | `my.notes.html` |

Rejected: absolute paths, empty / `.` / `..` segments, unsupported extensions,
empty stem (`.md`), oversize ids (> 255 UTF-8 bytes).

---

## Symlink policy (v0.1)

| Entry | Behavior |
|-------|----------|
| Directory symlink | **Reject** (`SymlinkRejected`); never enter / follow |
| Page-file symlink | **Reject** (`SymlinkRejected`); not registered as a page |
| Other symlink | **Reject** if encountered as a walk entry |

Stat calls for real entries use `follow_symlinks = false`.  
**Platform note:** symlink creation tests are skipped on Windows and when the
host denies symlink creation (`AccessDenied` / `PermissionDenied`).

---

## Duplicates

- **Same path-derived entity id, different source paths** (e.g. `same.md` and
  `same.mdx`): **both records kept**, sorted by `source_path`. Later graph
  validation issues `EDUPLICATEID` with both paths — discovery must not drop
  either side.
- Exact same walk path twice does not occur from a single selective walk.

---

## Errors

| Condition | Result |
|-----------|--------|
| Content root missing / not a directory | `ContentDirMissing` |
| Directory or page symlink under root | `SymlinkRejected` |
| Directory inode re-entry | `SymlinkCycle` |
| Illegal path / identity after normalize | `InvalidPath` |
| I/O / allocator failures | propagated |

---

## Non-goals (this milestone)

- Frontmatter parse
- Graph resolution / parent edges
- Product RAG generation
- Apex / HTML rendering
- Concurrency / watch mode
- mmap
- Following any content-tree symlink
