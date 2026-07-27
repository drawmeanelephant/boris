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

| Kind | Use for | Example Syntax |
|---|---|---|
| `note` | Background context, implementation details, helpful explanations | `&lt;Aside kind="note"&gt;...&lt;/Aside&gt;` |
| `tip` | Performance optimizations, best practices, efficiency suggestions | `&lt;Aside kind="tip"&gt;...&lt;/Aside&gt;` |
| `info` | General informational callouts and architectural notes | `&lt;Aside kind="info"&gt;...&lt;/Aside&gt;` |
| `warning` | Breaking changes, compatibility issues, potential problems | `&lt;Aside kind="warning"&gt;...&lt;/Aside&gt;` |
| `danger` | High-risk actions that could cause data loss or security issues | `&lt;Aside kind="danger"&gt;...&lt;/Aside&gt;` |

## Live Examples

Here are copy-pasteable snippets and live rendered examples for all 5 Aside kinds:

### 1. Note

```markdown
<Aside kind="note">

**Note:** Boris uses closed frontmatter. Only `title`, `parent`, `status`, `id`, and `tags` are accepted.

</Aside>
```

<Aside kind="note">

**Note:** Boris uses closed frontmatter. Only `title`, `parent`, `status`, `id`, and `tags` are accepted.

</Aside>

### 2. Tip

```markdown
<Aside kind="tip">

**Tip:** Use `boris check` in CI to validate content graph relationships before rendering.

</Aside>
```

<Aside kind="tip">

**Tip:** Use `boris check` in CI to validate content graph relationships before rendering.

</Aside>

### 3. Info

```markdown
<Aside kind="info">

**Info:** Bare `boris` builds HTML under `dist/`. IR mode requires `--out`, and RAG export requires `--rag`.

</Aside>
```

<Aside kind="info">

**Info:** Bare `boris` builds HTML under `dist/`. IR mode requires `--out`, and RAG export requires `--rag`.

</Aside>

### 4. Warning

```markdown
<Aside kind="warning">

**Warning:** The `parent` key must reference another page's exact entity id. File paths and titles are rejected.

</Aside>
```

<Aside kind="warning">

**Warning:** The `parent` key must reference another page's exact entity id. File paths and titles are rejected.

</Aside>

### 5. Danger

```markdown
<Aside kind="danger">

**Danger:** Do not edit files under `dist/` directly. Outputs are completely overwritten on build.

</Aside>
```

<Aside kind="danger">

**Danger:** Do not edit files under `dist/` directly. Outputs are completely overwritten on build.

</Aside>

## Rich Content Inside Asides

Asides support full Markdown formatting inside their body, including bold text, inline code, lists, and links:

```markdown
<Aside kind="tip">

### Best Practices

- Keep parent links explicit and validated.
- Use `&#91;&#91;wiki-links&#93;&#93;` for safe cross-referencing: see [[guides/overview|Overview]].
- Store reusable fragments in `content/includes/`.

</Aside>
```

<Aside kind="tip">

### Best Practices

- Keep parent links explicit and validated.
- Use `&#91;&#91;wiki-links&#93;&#93;` for safe cross-referencing: see [[guides/overview|Overview]].
- Store reusable fragments in `content/includes/`.

</Aside>

## Rules and constraints

- The opening tag <code>&lt;Aside kind="..."&gt;</code> and closing tag <code>&lt;/Aside&gt;</code> must each be on their own line.
- Always include blank lines between the tags and the Markdown body content.
- Asides are **in-document** components — they stay in document order and do not produce separate pages or navigation nodes.
- Only the `kind` attribute is accepted (`note`, `tip`, `info`, `warning`, `danger`). Unknown attributes or unrecognized tags produce a component error.
- Asides appear in RAG and IR export packaging using `:::kind` syntax — this is an export-only representation. Do not use `:::kind` syntax in your `content/` source files.

## Next steps

- [[guides/building-pages|Building Pages]] — other page authoring features
- [[guides/apex-markdown|Apex Markdown Reference]] — the full set of Markdown extensions Boris supports

