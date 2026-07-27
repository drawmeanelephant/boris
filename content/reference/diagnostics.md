---
title: Diagnostics & Troubleshooting
parent: reference
status: published
tags: [reference, errors, diagnostics]
---

# Diagnostics & Troubleshooting

Boris fails loudly when frontmatter or graph relationships are invalid. Validation runs during the **Roll phase** before any files are written to disk.

<Aside kind="info">

**Layer 1 Summary:** If a build fails with exit code `1`, Boris outputs a diagnostic error naming the exact file, line number, column, error code, and reason. No corrupted or partial output is written.

</Aside>

---

## Stable Error Codes & Solutions

| Diagnostic Code | Description / Cause | Actionable Solution |
|---|---|---|
| `EFRONTMATTER` | Frontmatter contains an unpermitted key or syntax error | Remove unpermitted keys. Allowed keys are **`id`**, **`title`**, **`parent`**, **`status`**, and **`tags`**. Ensure parent key is `parent:` (not `parentEntry`). |
| `EPARENTMISSING` | `parent:` names a page ID that does not exist in `content/` | Verify spelling of parent entity ID. Ensure the parent page exists under `content/`. |
| `EPARENTSELF` | A page names itself as its own `parent` | Remove or fix the self-referencing `parent` key. |
| `EPARENTCYCLE` | Parent links form a circular loop (A → B → A) | Break the cycle. Every path must terminate at a Trunk root page with no parent. |
| `EDUPLICATEID` | Two Markdown files resolve to the same entity ID | Rename one of the files or provide a unique `id:` override in frontmatter. |
| `EREFERENCEMISSING` | A wiki-link points to a non-existent page or target | Correct the target ID in your wiki-link tag (e.g. `[[getting-started]]`). |
| `EINCLUDEMISSING` | An include path cannot be found | Check file path relative to `content/`. Includes must live in `content/includes/`. |
| `EINCLUDECYCLE` | An include snippet transcludes itself directly or indirectly | Remove recursive include references. |
| `ECOMPONENT` | An Aside component has malformed syntax or unclosed tags | Check tag closing syntax: ensure `&lt;Aside kind="info"&gt;` has a matching `&lt;/Aside&gt;`. |

---

## Diagnostic Output Format

When an error occurs, Boris prints a standardized diagnostic format:

```text
error: EFRONTMATTER: content/getting-started.md:4:1: unknown key "author"
```

To validate your content graph without generating any output files:

```bash
./zig-out/bin/boris check
```

- Exit Code `0`: Graph is valid and ready to publish.
- Exit Code `1`: Diagnostic error detected.
- Exit Code `2`: Command-line usage error.
- Exit Code `3`: File system I/O error.

---

## Next Steps

- [[reference/frontmatter|Frontmatter Reference]] — Complete documentation of accepted YAML keys.
- [[reference/commands|CLI Reference]] — Flag definitions and exit codes.
