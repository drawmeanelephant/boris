---
title: Content Model Overview
status: published
tags: [guides, architecture]
---
# Content Model & Pipeline

Boris uses a strict **Trunk/Satellite** graph architecture. This isn't just a file system dump; it's a strongly validated dependency graph.

## The Pipeline: Load → Roll → Ignite → Reset

1. **Load (Discover)**: Boris scans `content/` for case-sensitive `.md` and `.mdx` files.
2. **Roll (Frontmatter & Graph)**: It parses the YAML frontmatter, validating exact keys (`title`, `parent`, `status`, `tags`). It then resolves the graph, ensuring every Satellite page points to a valid Trunk.
3. **Ignite (Emit/Render)**: Using Apex Markdown Unified, it renders the content to HTML, splicing it into `layouts/main.html`.
4. **Reset (Free Scratch)**: Per-page scratch memory is freed for the next parallel job.

## Navigation

- [Trunk vs Satellite](trunk-satellite.html): Learn how the graph model works.
- [Asides](asides.html): Learn how to write rich, semantic callouts.
