---
title: Asides & Admonitions
parent: guides/overview
status: published
tags: [guides, asides, components]
---

# Asides & Admonitions

Boris supports semantic callout blocks called **Asides**. Use them to draw attention to important information without breaking prose flow.

## Syntax

```markdown
<Aside kind="note">

This is a note. It appears inline with the content.

</Aside>
```

The `kind` attribute determines the visual style and semantic meaning.

## Available kinds

| Kind | Use for |
|---|---|
| `note` | Background context, implementation details, helpful explanations |
| `tip` | Performance optimizations, best practices, efficiency suggestions |
| `warning` | Breaking changes, compatibility issues, potential problems |
| `danger` | High-risk actions that could cause data loss or security issues |
| `info` | General informational callouts |

## Examples

<Aside kind="tip">

Use `boris check` to validate your content graph without generating any output files. This is useful in CI pipelines.

</Aside>

<Aside kind="warning">

The `parent` key must reference another page's exact entity id. File paths and display names are not accepted.

</Aside>

<Aside kind="danger">

Do not edit files under `dist/` directly. They are regenerated on every build and your changes will be lost.

</Aside>

## Rules and constraints

- The opening tag <code>&lt;Aside kind="..."&gt;</code> and closing tag <code>&lt;/Aside&gt;</code> must each be on their own line.
- Aside content is rendered as Markdown — you can use headings, lists, code blocks, and links inside an Aside.
- Asides are **in-document** components — they do not produce separate pages or navigation nodes.
- Only the `kind` attribute is accepted. Unknown attributes are rejected.
- Asides appear in RAG and IR export packaging using `:::kind` syntax — this is an export-only representation. Do not use `:::kind` syntax in your `content/` source files.

## Next steps

- [[guides/building-pages|Building Pages]] — other page authoring features
- [[guides/apex-markdown|Apex Markdown Reference]] — the full set of Markdown extensions Boris supports
