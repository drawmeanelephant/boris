---
rag_id: system/components-and-admonitions
rag_path: system/04-components-and-admonitions.md
category: system
tags: [components, asides, admonitions, directives, registry]
---


# Components and admonitions

Boris supports ordinary Markdown first and one constrained built-in documentation
component: **Aside**.

**Workshop analogy:** tools on the belt, not a second camp — callouts ride with
the page through Roll / Ignite, not as orphan satellites.  
**Invariant:** asides stay in document order; they are never graph nodes or
standalone fragment pages.

## Design rules

- Use standard semantic HTML where possible (`<aside>`, `<figure>`, …).
- Prefer clear generic terms: **Aside**, **admonition**, **component**.
- Do **not** invent branded names for ordinary docs features (“Broside” is
  unregistered → hard error).
- This is **not** generic HTML parsing, **not** MDX, and **not** markdown-native
  `:::` directive authoring.

## Built-in: Aside

```md
<Aside kind="tip" id="006-1">

Always declare `parent` on satellites (compiler dialect).

</Aside>
```

| Attribute | Required | Meaning |
|-----------|----------|---------|
| `kind` | no (default `note`) | Allowlist: `note`, `tip`, `info`, `warning`, `danger` |
| `id` | optional | Safe anchor: `[A-Za-z0-9][A-Za-z0-9_-]*` (1…64) |

Quoted attribute values only. Duplicate attributes and unknown names fail hard.
Close tag `</Aside>` only at **line start**. Nested Aside is rejected.

Recognition runs **only outside** fenced code blocks; literal `<Aside>` text
inside fences stays literal. Normative detail: `docs/contracts/components.md`.

## HTML and RAG

- HTML (opt-in path): ordered stream → Apex for markdown, `aside.renderHtml`
  for callouts → semantic `<aside class="admonition admonition--{kind}">`.
- RAG: export representation `:::kind` / `:::kind{id="…"}` only — **not**
  round-trippable authoring syntax.

## Registry policy

```text
Supported built-ins:
- Aside

Unknown PascalCase tags:
- Hard error (ECOMPONENT) with path, line, column, and tag name.

Never by default:
- Arbitrary executable components / JS expressions / unrestricted MDX
```
