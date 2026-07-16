# Closed component contract (v0.1)

**Status:** normative — **implemented** (milestone 10)  
**Modules:** `src/aside.zig` (tokenize + HTML + RAG directive format),  
`src/pipeline.zig` (hard validation on shared compile),  
`src/compile.zig` (experimental HTML stream),  
`src/rag.zig` (export representation)

This is **not** generic HTML parsing, **not** MDX, and **not** a generic
component registry. The only supported components are constrained **`<Aside>`**
and **`<Details>`**.

---

## Design rules

- Prefer the generic name **Aside** (admonition / callout). Do not invent branded
  component names (e.g. “Broside” is unregistered → hard error).
- Asides remain in **document order** on the containing page.
- Asides are **not** graph nodes and **not** standalone pages under `dist/`.
- Recognition happens **only outside** fenced code blocks (``` / ~~~).
- Literal component-looking text inside fences stays literal.

---

## Authoring syntax

```md
<Aside kind="tip" id="006-1">

Always declare `parent` on satellites.

</Aside>
```

### Close tag

The closing `</Aside>` must appear at the **start of a logical line** (optional
ASCII spaces or tabs before the tag). Mid-line `</Aside>` does **not** close.

### Attributes (quoted values only)

| Attribute | Required | Meaning |
|-----------|----------|---------|
| `kind` | no (default `note`) | Allowlist: `note`, `tip`, `info`, `warning`, `danger` |
| `id` | no | Safe in-page anchor (grammar below) |
| `type` | no | Legacy alias for `kind` (same allowlist; shares the kind slot) |

Rules:

- Values must be **double-quoted** (`kind="tip"`). Unquoted values are errors.
- No other attribute names.
- Duplicate attribute names (including `kind` + `type` together) are hard errors.
- Unterminated quotes / missing `>` fail with precise diagnostics.

### Optional `id` grammar

When present, `id` must match:

```text
[A-Za-z0-9][A-Za-z0-9_-]*   (1…64 bytes)
```

Parse-time rejection is the primary guarantee; HTML attribute sinks still escape
`& " < >` defensively.

### Nested Aside

**Rejected.** A second `<Aside` open before a matching line-start `</Aside>` is
a hard error (`nested_component` → pipeline code `ECOMPONENT`). No tag balancing
and no MDX-like trees.

## Details authoring

```md
<Details summary="Why does this matter?" id="why-details" open="true">

The body is ordinary Markdown.

</Details>
```

`Details` is a fixed native disclosure component, not an arbitrary HTML or
MDX escape hatch. Its close tag follows the same line-start rule as Aside.

| Attribute | Required | Meaning |
|-----------|----------|---------|
| `summary` | yes | Plain source text, non-empty, at most 256 UTF-8 bytes; rendered as escaped text, never Markdown |
| `id` | no | Same safe-anchor grammar as Aside |
| `open` | no | Only `open="true"` is accepted; renders the native boolean `open` attribute |

All values are double-quoted. Unknown or duplicate attributes, missing
`summary`, unquoted values, unterminated quotes, and malformed opening tags are
`ECOMPONENT` failures. `Aside` and `Details` cannot nest or cross-nest; for
example, closing an open Aside with `</Details>` is rejected.

HTML is exactly a native semantic shape with no client state or ARIA shim:

```html
<details class="details" id="why-details" open>
<summary>Why does this matter?</summary>
<div class="details__body">
…rendered Markdown body…
</div>
</details>
```

### Unknown PascalCase tags

Any open tag matching `<[A-Z][A-Za-z0-9_-]*` with a valid tag-name boundary that
is neither exactly `Aside` nor exactly `Details` is a **hard error** (`unregistered_component` →
`ECOMPONENT`). Tags are not silently left for Apex as free HTML.

Examples of hard errors: `<Figure>`, `<Broside>`, `<AsideFoo>` is **not** matched
as Aside (name boundary requires next byte space/`/`/`>` — `AsideFoo` is a
different unregistered name).

---

## Pipeline integration

On the **shared** `pipeline.compile` path (IR and RAG):

1. Frontmatter parse (`parser.parse`).
2. Body tokenize (`aside.tokenizeBody`).
3. Any component diagnostic → `ECOMPONENT` on the content diagnostic list.
4. Graph validate only after pages are promoted (component errors still fail the
   run with `ok: false`).

Experimental HTML (`compile.renderAndPublishPage`):

```text
segments → Apex(markdown) | Aside HTML | Details HTML → ordered HTML body
```

No raw registered-component tags in published HTML.

---

## RAG export representation

Parsed asides are inlined into the parent page segment as directive-style blocks:

```md
:::tip{id="006-1"}
Always declare parent…
:::
```

Details use an analogous inline projection retaining their closed metadata:

```md
:::details{summary="Why does this matter?" id="why-details" open="true"}
The body is ordinary Markdown.
:::
```

Without id:

```md
:::note
Body…
:::
```

Properties:

- **Export representation only** for retrieval — **not** the authoring grammar.
- **Not** round-trippable as input (Boris does not parse `:::` as authoring).
- No `rag/content/asides/` tree and no one-document-per-aside rule.

---

## Diagnostics

| Local kind | Pipeline code | Typical cause |
|------------|---------------|---------------|
| `unregistered_component` | `ECOMPONENT` | Unknown PascalCase tag |
| `unterminated_component` | `ECOMPONENT` | Missing line-start `</Aside>` |
| `nested_component` | `ECOMPONENT` | Nested or cross-nested Aside/Details |
| `invalid_kind` | `ECOMPONENT` | Kind not in allowlist |
| `invalid_id` | `ECOMPONENT` | Id fails safe-anchor grammar |
| `invalid_summary` | `ECOMPONENT` | Details summary missing, empty, multiline, or exceeds 256 bytes |
| `invalid_open` | `ECOMPONENT` | Details `open` value is not exactly `true` |
| `duplicate_attribute` | `ECOMPONENT` | Repeated attr name |
| `unknown_attribute` | `ECOMPONENT` | Non-allowlisted attr |
| `unterminated_quote` | `ECOMPONENT` | Unclosed `"` |
| `malformed_attribute` | `ECOMPONENT` | Unquoted / bad `key=value` |
| `missing_close_angle` | `ECOMPONENT` | Open tag without `>` |

---

## Explicit non-goals

- Generic HTML component systems / MDX / executable expressions
- Nested or cross-nested components
- Markdown-native `:::` authoring (export only)
- Standalone aside pages or graph nodes
- Concurrency

---

## Acceptance tests (minimum)

- Valid Aside and Details; optional id and Details `open`
- Invalid kind; duplicate attribute; unterminated quote
- Nested/cross-nested components; unknown component tag
- Component-looking text inside fenced code remains literal
- HTML escaping for attribute sinks
- RAG `:::kind` representation when RAG is enabled
- `zig build test` (includes `src/aside.zig` + `src/hardening_test.zig`)
