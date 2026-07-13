---
rag_id: system/components-and-admonitions
rag_path: system/04-components-and-admonitions.md
category: system
tags: [components, asides, admonitions, directives, registry]
related:
  - system/02-data-model-page.md
  - system/03-trunk-and-satellite.md
  - system/06-apex-native-engine.md
---

# Components and admonitions

Boris is a documentation-capable static-site compiler. It supports ordinary Markdown content first and may provide a small, explicit set of built-in documentation components.

## Design rules

- Use **standard semantic HTML** where possible (`<aside>`, `<figure>`, `<nav>`, `<pre><code>`).
- Do **not** use project-specific branded names for ordinary documentation features.
- Prefer clear generic terms: **Aside**, **admonition**, **component**, **directive**, **include**.
- A component remains in **document order** and renders as part of its containing page.
- Do **not** create standalone fragment pages or graph nodes for normal asides unless a later, concrete feature requires that behavior.
- Component extraction for search/RAG is optional and must consume the validated document representation; it must **not** dictate authoring or rendering.

## Built-in: Aside (admonition)

Authoring syntax (HTML-like, constrained — not MDX):

```md
<Aside kind="tip" id="006-1">

Always declare `parentEntry` on satellites.

</Aside>
```

Attributes:

| Attribute | Required | Meaning |
|-----------|----------|---------|
| `kind` | preferred | Semantic kind: `note`, `tip`, `info`, `warning`, `danger` (legacy `type=` accepted as alias) |
| `id` | optional | Stable in-page anchor only when set |

## Parser behavior (`src/parser.zig`)

1. Scan body for real `<Aside` tags (not longer identifiers like `AsideFoo`)
2. Read attributes (`kind` / legacy `type`, `id`) — zero-copy slices
3. Capture inner body until `</Aside>` — zero-copy slice into source
4. Produce an **ordered segment list**: markdown | aside | markdown | …
5. Also build `body_md` with component spans stripped (tooling convenience)

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

## RAG behavior

Asides are **inlined** into the parent page RAG segment as directive-style blocks:

```md
:::tip{id="006-1"}
Always declare parentEntry…
:::
```

There is no `rag/content/brosides/` tree and no one-document-per-aside rule.

## Roadmap (extension path)

1. **v0.1 (current):** Standard Markdown + constrained `<Aside>` built-in
2. **v0.2:** Markdown-native `:::kind` admonition directives
3. **v0.3:** Explicit registry for more block components (`Figure`, `Tabs`, `Include`)
4. **Never by default:** arbitrary executable components, JS expressions, or “accept any tag and hope a template exists”

## Registry policy

```text
Supported built-ins:
- Aside (admonition / Callout alias may be added later)
- (planned) Figure, Card, Tabs, Include

Unknown components:
- Build error with file path, line, column, and component name (hardening path).

Component properties:
- Documented allowlist per component.
- String, boolean, and simple identifier values only at first.
- No expressions, JavaScript, or arbitrary code execution.
```

Internal typed tokens may be called `Block`, `Directive`, `ComponentNode`, or `Aside` — not a mascot name.
