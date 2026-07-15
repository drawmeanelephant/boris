---
title: Boris Docs Compiler
status: published
tags: [home, zig]
---
# Welcome to Boris

Boris is a **Zig static-site compiler** for Markdown documentation. 

Our philosophy is simple: **Load → Roll → Ignite → Reset**. We provide a validated content metadata model, graph-aware navigation, and semantic admonitions out of the box.

<Aside kind="info">
Boris now defaults to an HTML site build under `dist/` and uses real **ApexMarkdown Unified** for rendering. No more "IR-first" generic claims. We are a docs site builder.
</Aside>

## Why Boris?

Unlike traditional SSGs, Boris isn't a polyglot web framework. There's no Node SSG stack, no React, no Webpack. 

### Core Features

- **Blazing Fast**: Written in Zig 0.16+.
- **Validated Graph**: Strict Trunk/Satellite content model ensures you never have dangling docs.
- **Apex Markdown**: Fully featured markdown via C ABI host adapter.
- **Zero-JS by Default**: Layouts are pure HTML splices, keeping the payload lean.

Check out [Getting Started](getting-started.html) to begin, or dive into our [Apex Showcase](guides/apex-markdown.html) to see the renderer in action!
