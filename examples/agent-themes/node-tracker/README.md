# Node Tracker theme

A compact knowledge-database theme inspired by early-2000s Everything2-style
node pages: dense typography, blue chrome, writeups, nodelets, reputation
metadata, and an unapologetically information-first layout.

This is a static Boris showcase, not an Everything2 clone. Search, login,
reputation, bookmarking, and account controls are visual-only and are marked
as such in the layout. There is no JavaScript, CDN, framework, or runtime
dependency.

## Build

```bash
./zig-out/bin/boris \
  --input examples/agent-themes/node-tracker/content \
  --theme examples/agent-themes/node-tracker/theme \
  --html-dir test-output/node-tracker \
  --quiet
```

The index page is the Trunk. Each writeup is a Satellite linked with
`parent: index`; `{{children}}` gives the node its deterministic writeup stream.
