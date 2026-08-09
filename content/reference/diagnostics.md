---
title: Diagnostics & Troubleshooting
parent: reference
status: published
tags: [reference, errors, diagnostics]
---

# Diagnostics & Troubleshooting

Boris reports deterministic diagnostics with an error code, source path, and
location where one is available. Content and graph failures use exit `1`;
usage conflicts use exit `2`; I/O and system failures use exit `3`.

## Compiler diagnostics

| Code | Meaning | First action |
|---|---|---|
| `EFRONTMATTER` | Closed frontmatter syntax, unknown key, duplicate key, or value error | Compare the file with [[reference/frontmatter|the eight-key grammar]] |
| `EINVALIDUTF8` | Source, layout, or other input is not valid UTF-8 | Rewrite the file as UTF-8 without a leading BOM |
| `EINVALIDPATH` | Entity id, input path, or output path violates path rules | Use `/`-separated non-empty safe segments |
| `EPARENTMISSING` | `parent` names no discovered page | Use the exact parent entity id |
| `EPARENTSELF` | A page names itself as its parent | Remove or correct `parent` |
| `EPARENTCYCLE` | Parent edges form a cycle | Break the cycle so the chain ends at a Trunk |
| `EDUPLICATEID` | Two pages resolve to one entity id | Rename a page or set a unique `id` |
| `EREFERENCEMISSING` | A Boris wiki-link target is missing or not eligible | Fix the target id or publish the target |
| `EINCLUDEMISSING` | An include fragment cannot be found | Check the content-root-relative path under `includes/` |
| `EINCLUDECYCLE` | Include directives recurse | Remove the cycle |
| `ECOMPONENT` | `&lt;Aside&gt;` or `&lt;Details&gt;` syntax/attribute error | Check the constrained component grammar |

The exact installed binary remains the final surface authority:

```bash
./zig-out/bin/boris --help
```

## Validate, build, and check

Use the command that matches the question:

```bash
# Compiler-authoritative HTML preflight; writes no output.
./zig-out/bin/boris validate --input content

# Publish the selected output after the shared graph gate.
./zig-out/bin/boris build --input content --html-dir dist

# Documentation-Intelligence health report over a valid frozen graph.
./zig-out/bin/boris check --input content --format json --report health.json
```

`validate` checks the HTML source/configuration path, including layouts,
themes, targets, and sitemap configuration. It is not an alias for `check`.
`check` can return exit `1` for a policy finding such as `unreferenced_page`
even when `validate` and `build` succeed. `check` does not inspect rendered
HTML, CSS, theme assets, accessibility, or external URLs.

For dependency direction:

```bash
./zig-out/bin/boris impact guides/overview --input content
```

`impact` reports transitive dependents using parent/include/reference
dependencies. Semantic `relations` are intentionally not dependency edges.

## Reading a diagnostic

Example:

```text
error: EFRONTMATTER: content/guides/page.md:4:1: unknown key "sidebar_position"
```

The path and 1-based location identify the source field. Fix the smallest
source issue first, then rerun `validate`; a later graph error may disappear
once frontmatter parses.

## Common causes

| Symptom | Cause | Resolution |
|---|---|---|
| `unknown key "parentEntry"` | Legacy frontmatter spelling | Rename it to `parent` |
| `parent ... not found` | Parent value is a title, filename, or stale id | Use the exact entity id, such as `guides/overview` |
| `reference ... not found` | Wiki-link target is missing, draft, or misspelled | Correct the id or change the target status |
| `missing include` | Fragment path is wrong or outside the content root | Put the fragment under `content/includes/` and use its root-relative path |
| `component` error | Unsupported tag, attribute, nesting, or quote form | Use `&lt;Aside&gt;` or `&lt;Details&gt;` exactly as documented |
| `Exit 2` | Conflicting projection or invalid CLI value | Separate HTML, IR, RAG, Context, `llms.txt`, RSS, and analysis commands |
| `Exit 3` | Missing input, unreadable layout, or output I/O failure | Check paths and permissions, then rerun |

## Minimal troubleshooting loop

1. Run `boris validate --input content`.
2. Fix frontmatter and graph diagnostics in source order.
3. Run `boris build --input content --html-dir .tmp/site`.
4. Inspect the generated route and, if needed, run `boris check` separately.

The compiler does not repair source files or silently map unsupported metadata.

## Related pages

- [[reference/frontmatter|Frontmatter Reference]] — accepted metadata
- [[reference/commands|Command Reference]] — flags and exit codes
- [[reference/relationships|Relationships]] — graph and dependency edges
- [[guides/asides|Asides & Admonitions]] — component syntax
