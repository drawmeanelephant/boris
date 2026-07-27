---
title: Diagnostics
parent: reference
status: published
tags: [reference, errors]
---

# Diagnostics

Boris fails loudly when source relationships are unsafe. Start with the stable
diagnostic code, then fix the named file and rebuild. A content failure exits
`1`; an invalid command exits `2`; an I/O failure exits `3`.

## The errors authors see most often

| Code | Usually means | First fix to try |
|---|---|---|
| `EFRONTMATTER` | An unknown key, malformed field, or YAML-like construct | Compare the header with [[reference/frontmatter|Frontmatter Reference]] |
| `EPARENTMISSING` | `parent:` names no page | Use the exact entity id of an existing page |
| `EPARENTSELF` | A page names itself as parent | Remove or correct `parent:` |
| `EPARENTCYCLE` | Parent pages loop back to each other | Break the cycle; every chain needs a Trunk root |
| `EDUPLICATEID` | Two source files resolve to one id | Rename a path or add one distinct `id:` override |
| `EREFERENCEMISSING` | A wiki-link page or heading target does not exist | Correct the target id or rebuild once and copy the rendered heading id |
| `EINCLUDEMISSING` | An include file cannot be read | Check the content-root-relative include path |
| `EINCLUDECYCLE` | Includes expand back into themselves | Make the shared fragment one-directional |
| `ECOMPONENT` | An Aside or registered component is malformed | Check tag spelling, quoted attributes, and closing tag |
| `EINVALIDUTF8` | Source is not UTF-8, or begins with a UTF-8 BOM | Save as BOM-free UTF-8 |

## Read the location before changing the model

Human-readable diagnostics name a source path, line, and column when known:

```text
error: EFRONTMATTER: bad.md:2:1: unknown key "category"
```

The same structured diagnostic appears in the JSON build report for IR builds.
The code is stable; the message is there to tell you what to change. Do not
paper over a graph error with a regular Markdown link—use the intended
`parent`, include, or wiki-link relationship.

## A quick recovery loop

1. Read the first error and its source location.
2. Make the smallest source correction.
3. Run `boris check` when you only want validation, or `boris` to publish.
4. If the error names a heading fragment, inspect the generated heading id and
   update the page-and-heading target exactly.

For the full, machine-facing diagnostic contract, see the
[repository contract](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/diagnostics.md).
