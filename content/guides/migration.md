---
title: Migrating to Boris
parent: guides/overview
status: published
tags: [guides, migration]
---

# Migrating to Boris

Boris does not auto-convert other site generator formats. Instead, it provides **review-first tooling** that helps you understand your existing content before porting it manually or incrementally. This guide explains the recommended workflow.

## Why review-first?

Direct auto-conversion from Hugo, Astro, Starlight, or other systems tends to silently map concepts that do not translate cleanly: proprietary frontmatter keys, MDX components, shortcodes, complex hierarchies. The result is a site that compiles but does not behave as expected.

Boris's approach: inspect your source content, understand what you have, then convert deliberately. The migration lab tools produce **review reports** — not automatic output files.

## Step 1: Inspect your source content

Use the migration lab to analyze your existing content tree:

```bash
zig build --build-file tools/migration-lab/build.zig run -- \
  --source /path/to/my-old-site/content \
  --mode frontmatter-review \
  --report frontmatter-review.md
```

This reads all Markdown files under `--source` and produces a report of:
- Frontmatter keys found and their frequency
- Unknown keys (those that Boris would reject)
- `parent` equivalents from common SSG formats
- Draft and status patterns

## Step 2: Map your content hierarchy

Boris requires an explicit `parent` key for every Satellite page. Most SSGs derive hierarchy from directory structure, config files, or sidebar definitions. You will need to make these relationships explicit.

A common pattern:

| Old SSG | Hierarchy source | Boris equivalent |
|---|---|---|
| Hugo | Directory structure + `_index.md` | `parent` in frontmatter |
| Starlight | Sidebar config in `astro.config.mjs` | `parent` in frontmatter |
| Docusaurus | `sidebar.js` | `parent` in frontmatter |
| Plain Markdown | Directory structure | `parent` in frontmatter |

For sites with complex sidebars, run the relationship candidate extractor:

```bash
zig build --build-file tools/migration-lab/build.zig run -- \
  --source /path/to/my-old-site \
  --mode relationship-review \
  --report relationship-candidates.md
```

This identifies candidate `parent` relationships based on directory structure and common patterns. The report is for **human review** — Boris does not auto-select relationships.

## Step 3: Convert pages incrementally

Start with a small representative section of your site. For each page:

1. Create the file under `content/` with a Boris-compatible path.
2. Rewrite frontmatter to use only the five Boris keys (`id`, `title`, `parent`, `status`, `tags`).
3. Replace SSG-specific shortcodes with Boris equivalents:
   - Callout/admonition blocks → <code>&lt;Aside kind="..."&gt;</code>
   - Cross-page links → `<pre><code>&#91;&#91;entity-id&#124;Link text&#93;&#93;</code></pre>` wiki-links
   - Transclusion/includes → `<pre><code>&#123;&#123;include includes/snippet.md&#125;&#125;</code></pre>`
4. Remove MDX `import` statements and executable component usage.

## Step 4: Validate before expanding

```bash
./zig-out/bin/boris check
```

Validate the graph before adding more pages. Fix any `EGRAPH` or `EFRONTMATTER` errors before continuing.

## Step 5: Expand and iterate

Once a section validates cleanly, add the next section and repeat. Boris's validation model means you cannot accidentally publish a broken state — broken references fail loudly.

## What Boris does not support

- **Arbitrary MDX** — Boris does not execute JavaScript expressions or allow arbitrary React/Vue/Svelte components. Use <code>&lt;Aside&gt;</code> for callouts and Boris wiki-links for cross-page references.
- **Multiple frontmatter parents** — Each page has exactly one parent or is a Trunk.
- **Auto-generated sidebar config** — Navigation is derived from the validated graph. There is no sidebar config file.
- **Template inheritance beyond layouts** — Boris layouts are single HTML files with marker tokens, not a Jinja/Nunjucks-style inheritance system.

## Next steps

- [[guides/building-pages|Building Pages]] — Boris's authoring model
- [[reference/frontmatter|Frontmatter Reference]] — accepted keys
- [[guides/overview|Content Model]] — understanding the graph-based hierarchy
