---
title: "`src/doclink.zig` surface and execution"
id: docs/boris/src/doclink/surface-and-execution
parent: docs/boris/src/doclink
status: draft
tags: [boris, zig, source-reference, surface, doclink]
---

# `src/doclink.zig` surface and execution

## Public API

```zig
pub const Options = struct {
    nodes: []const graph_mod.Node,
    source_path: []const u8,  // content-root-relative owning page
    output_path: []const u8,  // published HTML path of that page
};

pub fn rewrite(allocator, body, options) ![]u8
```

- Builds a `StringHashMap` of `node.source_path → Node` (first wins on duplicate keys).
- Empty graph → duplicate of `body` only.
- Returned buffer is allocator-owned; caller (Whiteboard arena) owns lifetime.[^4_1]

No diagnostics type here: unresolved / unsafe / non-page destinations stay **literal**; only OOM and internal alloc failures error.[^4_1]

***

## What gets rewritten

Only **inline** Markdown links of the form:

`[label](destination)` optionally with title, angle-bracket dest, escapes.


| Condition | Behavior |
| :-- | :-- |
| Path ends with `.md` or `.mdx` | Candidate for resolve |
| Resolves to a graph node’s `source_path` | Destination replaced with `relativeHref(from_output, target.html)` + original `?…` / `#…` suffix |
| Otherwise | Left unchanged |

Label text, titles, and surrounding syntax are **not** rewritten—only the destination span.[^4_1]

***

## Scan state machine (`rewrite` loop)

Walks `body` with mutually exclusive “skip” modes:

1. **Fenced code** — line-start fence (optional ≤3 spaces, ````` or `~`, run ≥3); close matching char + run ≥ open; whole line skipped while open.
2. **HTML block** — line-start block tag / comment / `?` / `![CDATA`; rest of line + following lines until blank line (implementation clears `html_block` after consuming a line while set—block-ish skip).
3. **Raw HTML** — `<` then either `<!--…-->` or until `>`.
4. **Code spans** — backtick runs; matching run length toggles `code_run`.
5. **Images** — `![` is **not** treated as a doc link (`i == 0 or body[i-1] != '!'` guard on `[`).

Only when not in fence/html/code and `[` starts a link (not image): `findLabelEnd` → `parseDestination` → `rewriteDestination`.[^4_1]

Helpers:

- `isEscaped` — odd number of `\` before index
- `findLabelEnd` — nested `[]`, respect escapes
- `parseDestination` — `(…)` with optional `<dest>`, balanced parens, optional title (`"` / `'`), sets `Destination{start,end,link_end}`
- `skipSpace`, `findTitleEnd`[^4_1]

***

## Path resolution (source namespace, not URLs)

### `splitSuffix`

Splits destination at first `?` or `#` → `{ path, suffix }`. Suffix is appended unchanged after a successful rewrite.[^4_1]

### Hard rejects → `null` (literal keep)

- Empty path
- Any `\`
- Leading `/` (site-absolute)
- `schemePrefix` (alpha + alnum/`+`/`-`/`.` then `:`) — `http:`, `mailto:`, etc.
- Path that does not end with `.md` / `.mdx`
- Resolve failure or no graph node
- `htmlOutputPath` / `relativeHref` failure[^4_1]


### `resolveSourcePath`

- Root-relative if path starts with `/` already rejected above; **content-root relative** uses optional leading `/` stripped only when `root_relative` was true—here root-relative Markdown paths like `/guide.md` are rejected by leading `/`. Relative paths join against **dirname of owning `source_path`**.
- Segment split on `/`; empty segments → fail.
- Per segment: `encodedTraversal` rejects `%`-decoding that yields `.` / `..` / `\` / `/` or bad hex.
- `.` skipped; `..` pops stack (fail if empty).
- Rebuild with `/` separators.[^4_1]


### Map lookup → href

```text
resolved source path → Node
→ identity.htmlOutputPath(node.id)
→ identity.relativeHref(options.output_path, target_output)
→ href ++ suffix
```

Uses **entity id** for the HTML path (id override changes public URL even if source path differs).[^4_1]

***

## Intentional non-goals / limitations

- Not a full CommonMark link parser (reference links, autolinks, definition lists ignored).
- Not an HTML post-pass (`<a href="…">` left alone).
- Not a site-wide link checker (broken targets stay literal).
- Images handled elsewhere (`content_asset`).
- Wiki `&#91;&#91;id]]` handled by `wikilink`.
- Includes: links inside **included** bodies keep fragment’s own resolution context only if rewritten before include of that fragment’s file as a page; when expanded into another page, doclink already ran on the parent body only—comment in `html_body` calls this a **first-slice limitation**.[^4_1]
- Duplicate `source_path` keys: first node wins in the hash map.[^4_1]

***

## Comparison with neighbors

| Concern | `doclink` | `wikilink` | `content_asset` images |
| :-- | :-- | :-- | :-- |
| Syntax | `[t](path.md)` | `&#91;&#91;entity]]` | `![alt](path)` |
| Key | Source path in graph | Entity id | Sibling `.assets` tree |
| Missing target | Silent literal | Hard fail + diag | Hard fail + diag |
| Output | Relative `.html` | Relative `.html` + fragment | Relative asset URL |
| Order | First | After includes | After wiki |

[^4_1]

***

## Memory / ownership

- Temporary map keys are **views** into `Node.source_path` (PageDb / frozen graph lifetime).
- `resolveSourcePath` / intermediate hrefs freed with `defer` inside rewrite helpers.
- Final body is a single owned slice; on error, `errdefer` frees the building `ArrayList`.
- Safe for Whiteboard: no retention past `rewrite` return.[^4_1]

***

## Engineering fit (Boris principles)

- **Correctness before cleverness**: closed Markdown boundary; fail closed on encoded traversal; no filesystem IO.
- **Data-oriented**: flat node slice in, hash map for O(1) source lookup, deterministic string emit.
- **Generic frontend**: only emits relative HTML paths via `identity`, not Astro-specific URLs.
- **Small vertical slice**: ~17KB, pure + tests, no concurrency.[^4_1]

***

## Suggested review checklist

1. Confirm product docs state that ordinary Markdown links are **best-effort rewrite**, not validation (README already notes they are not a full link checker).[^4_2]
2. If include fragments must resolve against the **including** page, that needs a second pass or rewrite-after-expand design—currently out of scope.[^4_1]
3. Prefer wiki-links when missing targets must fail the build.
4. Keep `.md`/`.mdx` case-sensitive (`.MD` stays literal)—aligned with identity extension policy.[^4_1]
5. Any new link forms (reference-style, autolink) need explicit design; do not silently half-parse.

***

## Confirmed vs suggestion

| Confirmed in repo | Suggestion / assumption |
| :-- | :-- |
| Module header, `Options`, `rewrite`, helpers, tests in packed `src/doclink.zig` | — |
| Wired first in `html_body.renderSource` before includes | — |
| Soft-fail missing targets | Hard-fail mode could be a later flag; not present |
| Include-fragment link context limitation documented in `html_body` | Second-pass rewrite after includes if authors need it |

That is the same style of end-to-end read as the other `src/*` dossiers: contract, call order, algorithms, non-goals, tests, and review hooks.
<span style="display:none">[^4_3]</span>

<div align="center">⁂</div>

[^4_1]: boris-source-2.md

[^4_2]: boris-source-1.md

[^4_3]: boris-source-3.md
