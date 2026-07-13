---
rag_id: system/components-and-admonitions
rag_path: system/04-components-and-admonitions.md
category: system
tags: [components, asides, admonitions, directives, registry]
related:
  - system/02-data-model-page.md
  - system/03-trunk-and-satellite.md
  - system/06-apex-native-engine.md
  - system/10-name-and-metaphor.md
---

# Components and admonitions

Boris is a documentation-capable static-site compiler. It supports ordinary Markdown content first and may provide a small, explicit set of built-in documentation components.

Metaphorically: **tools on the belt**, not a second camp — callouts ride with the
page through **Roll / Ignite**, not as orphan satellites. See
[system/10-name-and-metaphor.md](10-name-and-metaphor.md).

## Design rules

- Use **standard semantic HTML** where possible (`<aside>`, `<figure>`, `<nav>`, `<pre><code>`).
- Do **not** use project-specific branded names for ordinary documentation features.
- Prefer clear generic terms: **Aside**, **admonition**, **component**, **directive**, **include**.
- A component remains in **document order** and renders as part of its containing page.
- Do **not** create standalone fragment pages or graph nodes for normal asides unless a later, concrete feature requires that behavior.
- Component extraction for search/RAG is optional and must consume the validated document representation; it must **not** dictate authoring or rendering.
- This is **not** generic HTML parsing, **not** MDX, and **not** markdown-native `:::` directive authoring in the tokenizer.

## Built-in: Aside (admonition)

Authoring syntax (HTML-like, constrained — not MDX):

```md
<Aside kind="tip" id="006-1">

Always declare `parent` on satellites (compiler dialect).

</Aside>
```

The closing `</Aside>` must appear at the **start of a logical line** (optional
ASCII spaces or tabs before the tag). Same-line closes are not recognized.

Attributes:

| Attribute | Required | Meaning |
|-----------|----------|---------|
| `kind` | preferred | Semantic kind allowlist: `note`, `tip`, `info`, `warning`, `danger` (legacy `type=` accepted as alias for the same allowlist) |
| `id` | optional | Stable in-page anchor; safe identifier only (see below) |

No other attributes are accepted. Duplicate `kind` / `id` / `type` names on one
open tag are hard errors.

### Id grammar

When `id` is present it must match:

```text
[A-Za-z0-9][A-Za-z0-9_-]*   (1…64 bytes)
```

This keeps ids safe for HTML `id="…"` and RAG `:::kind{id="…"}` sinks without
relying on ad-hoc escaping of author input. Quotes, spaces, `}`, `<`, and other
special characters are rejected at parse time.

## Parser behavior (`src/parser.zig`)

Single forward-only pass over the body **after** frontmatter:

1. **UTF-8 gate** — invalid UTF-8 is rejected before any byte-oriented tag scan
   (`parsePageSource` also rejects a UTF-8 BOM).
2. **Lexical boundary** for `<Aside` — next byte must be whitespace, `/`, or
   `>`; not a longer identifier like `AsideFoo`.
3. **Registered components only** — unknown PascalCase opens are hard errors
   with path, line, column, and tag name (`E_COMPONENT`).
4. **Attribute scan** — hand-rolled key/value parser for allowlisted names only
   (`kind`, `id`, legacy `type`); zero-copy slices; duplicates and unknown names
   are diagnostics.
5. **Kind allowlist** — when `kind`/`type` is present, value must be one of
   `note|tip|info|warning|danger`.
6. **Close tag** — only line-start `</Aside>` (optional leading spaces/tabs).
   Mid-line `</Aside>` (including inline examples) does **not** terminate.
   Fences are **not** a second grammar: a line-start `</Aside>` inside a fenced
   code block still closes an open Aside.
7. **Ordered segments** — markdown | aside | markdown | …
8. **`body_md`** — join markdown segments only (not a second raw-source scan).
9. **Diagnostics** — multi-issue list; compile/RAG must refuse emit when any
   component diagnostic is present.

### Nested asides (unsupported)

Nesting is **not** supported. A second `<Aside` open before the matching
line-start `</Aside>` is a hard error (`nested_component`). The tokenizer does
not balance nested tags and does not invent MDX-like trees. Asides remain
document-local segment tokens — never graph nodes.

### Unregistered / unterminated components

- Any PascalCase open tag `<[A-Z][A-Za-z0-9_-]*` that is not in the allowlist is a
  **hard build error** with path, line, column, and component name
  (`E_COMPONENT`). Tags are not silently left to Apex as free HTML.
- An opening `<Aside` without a matching **line-start** `</Aside>` is a hard
  error (`unterminated_component`). The remainder of the file is **not**
  swallowed as the aside body.

### Naming

Canonical tag: **`Aside`**. Legacy mascot branding (**Broside**) is **not**
registered and produces `unregistered_component`. Do not reintroduce branded
names for ordinary docs features.

## Compile behavior (`src/compile.zig` + `src/aside.zig`)

```text
Markdown input
  → block/component tokenizer
  → ordered document token stream
  → Markdown renderer (Apex) for markdown blocks
  → component renderer for registered components
  → one ordered HTML body
  → page template/layout
  → final HTML file under dist/
```

Expected semantic output:

```html
<aside class="admonition admonition--tip" id="006-1" aria-label="Tip">
  <p class="admonition__title">Tip</p>
  <div class="admonition__body">…</div>
</aside>
```

- No raw `<Aside>` tags in `dist/`
- **No** `dist/_brosides/` or other fragment trees for callouts
- CSS BEM-style: `admonition`, `admonition--{kind}`, `admonition__title`, `admonition__body`
- HTML attribute sinks still escape `& " < >` as defense in depth; parse-time id
  grammar is the primary guarantee for author-controlled ids.

## RAG behavior

Asides are **inlined** into the parent page RAG segment as directive-style blocks:

```md
:::tip{id="006-1"}
Always declare parent…
:::
```

There is no `rag/content/brosides/` tree and no one-document-per-aside rule.
Parse-time id/kind allowlists keep these directive lines from being broken by
quotes or special characters in attributes.

## Roadmap (extension path)

1. **v0.1 (current):** Standard Markdown + constrained `<Aside>` built-in
2. **v0.2:** Markdown-native `:::kind` admonition directives (authoring sugar;
   not required for the current tokenizer)
3. **v0.3:** Explicit registry for more block components (`Figure`, `Tabs`, `Include`)
4. **Never by default:** arbitrary executable components, JS expressions, or “accept any tag and hope a template exists”

## Registry policy

```text
Supported built-ins:
- Aside (admonition / Callout alias may be added later)
- (planned) Figure, Card, Tabs, Include

Unknown components:
- Build error with file path, line, column, and component name (`E_COMPONENT`).

Component properties:
- Documented allowlist per component.
- String, boolean, and simple identifier values only at first.
- No expressions, JavaScript, or arbitrary code execution.
```

Internal typed tokens may be called `Block`, `Directive`, `ComponentNode`, or `Aside` — not a mascot name. **Broside is deprecated / rejected.**
