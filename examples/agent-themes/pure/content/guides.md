---
title: Guides
status: published
tags: [guides, theme]
---

# Guides

The Guides Trunk uses the section layout. Its direct Satellites are surfaced
before the article so a reader can choose a path without hunting through a
long navigation tree.

## What this guide covers

| Page | Focus |
| --- | --- |
| [Getting started](guides/getting-started.md) | Compile, inspect, and repeat the theme build |
| [Reference](reference.md) | Layout markers, styling hooks, and boundaries |

<Aside kind="note">

This page is a Trunk because it owns a Satellite. Satellites declare their
parent in frontmatter with the canonical `parent` key.

</Aside>

## A useful reading order

1. Run `zig build` to produce the local Boris binary.
2. Compile this example into an ignored `test-output/` directory.
3. Inspect the generated landmarks and asset paths.
4. Repeat the build into a second directory and compare manifests.
