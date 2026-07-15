# Includes and wiki-links (Boris-mediated)

**Status:** normative contract — **implemented** on the HTML path (product v0.2+)  
**Modules:** [`src/include.zig`](../../src/include.zig), [`src/wikilink.zig`](../../src/wikilink.zig),
wired from [`src/compile.zig`](../../src/compile.zig)  
**Related:** [html-output.md](html-output.md), [diagnostics.md](diagnostics.md),
[apex-abi.md](apex-abi.md), [scanner.md](scanner.md)

---

## Goals

- Expand Markdown includes and resolve wiki-links **in Zig before Apex**.
- Keep Apex sandboxed: `enable_file_includes = false` always (never engine FS reads).
- Fail loud on missing targets, illegal paths, and include cycles.
- Include file bytes contribute to the parent page’s HTML cache fingerprint.
- Do **not** publish include/reference edges in IR `graph.json` under
  `schemaVersion` `0.1.0` (internal `DependencyIndex` only).

---

## Author syntax

### Includes

```markdown
{{include path/to/fragment.md}}
```

| Rule | Detail |
|------|--------|
| Form | `{{include` + whitespace + path + `}}` |
| Path | Content-root relative; segments `[A-Za-z0-9._-]`; no `..`, no absolute, no `\` |
| Target body | If target has closed frontmatter fences, use **body only** |
| Nesting | Includes may include further includes |
| Cycles | Hard error `EINCLUDECYCLE` |
| Missing | Hard error `EINCLUDEMISSING` |
| Fences | No expansion inside fenced code blocks |
| Discovery | Content-root directory **`includes/`** is **not** discovered as pages |

Recommended layout: fragment files under `content/includes/**`. Nested
directories named `includes` elsewhere (e.g. `guides/includes/`) remain normal
pages if they contain `.md` / `.mdx`.

### Wiki-links

```markdown
[[entity-id]]
[[entity-id|display label]]
```

| Rule | Detail |
|------|--------|
| Target | Exact **entity id** (same space as `parent`) |
| Display | Optional `\|label`; default = page `title` if set, else entity id |
| Output | Rewritten to `[label](relative-href)` using HTML output paths |
| Missing | Hard error `EREFERENCEMISSING` |
| Fences | No rewrite inside fenced code |
| Sections | `[[id#heading]]` **not** supported in this MVP |

---

## Resolve order (HTML)

1. Fence-aware **include expansion** (depth limit 32 + cycle stack).
2. Fence-aware **wiki rewrite** against frozen graph nodes.
3. **Aside** tokenize.
4. **Apex** render markdown segments.

Coordinator phases (discover, parent graph freeze, include plan, fingerprint)
stay sequential. Workers only render with precomputed deps.

---

## Fingerprints

Page fingerprint inputs (see `cache.computePageFingerprint`) include:

- Source file bytes (directives still present in source).
- Transitive include **file** bytes (stable path order).
- Compact **reference material** for wiki targets: entity id, output path, and
  title, sorted by id. Targets are the **union** of wiki-links in the page body
  **and** in every transitive include fragment body (`referenceMaterialMulti`).
  A title/path rename of a page that is only wiki-linked via an include still
  dirties the including parent.
- Layout bytes and optional site-nav material when `{{nav}}` is present.

---

## Diagnostics

| Code | When |
|------|------|
| `EINCLUDESYNTAX` | Malformed `{{include …}}` |
| `EINCLUDEMISSING` | Target path not found / unreadable |
| `EINCLUDECYCLE` | Transclusion cycle (or depth exceeded) |
| `EREFERENCESYNTAX` | Malformed `[[…]]` |
| `EREFERENCEMISSING` | Wiki target entity id not in graph |
| `EINVALIDPATH` | Illegal include path segments |

HTML path emits **structured** text diagnostics via `diag.formatText`:

```text
error: EINCLUDEMISSING: path/to/page.md:line:col: message [remediation]
```

- Codes above map from include/wiki failures (not bare `@errorName`).
- Fields are **retain-owned** (copied into fail buffers / duped for print; no
  views into temporary include file bytes).
- **Locus:** nested include/wiki failures report the fragment path where the
  directive or wiki-link actually appears (e.g. `includes/outer.md:2:1`), not
  only the parent page. Root-page failures keep the page source path.
- Line/column are relative to the **body** of that locus file (after closed
  frontmatter strip when present).
- Printed at **plan-time** (`SharedCompileState` transitive include collect) and
  at **render-time** (expand / wiki rewrite) and fingerprint wiki material when
  a missing/malformed reference is discovered.
- Process exit **1** for content failures. CLI does not re-print a generic
  `IncludeFailed` / `ReferenceFailed` / `GraphValidationFailed` line after a
  structured diagnostic has already been written.

---

## Non-goals (this contract)

- IR `graph.json` edge kinds for include/reference (would require schema bump).
- Apex-native includes or wiki plugins.
- Soft warnings for broken links.
- Heading-fragment wiki targets (`#section`).
