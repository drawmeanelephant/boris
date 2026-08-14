# Cozy Corner theme

A warm, two-column personal-blog theme inspired by mid-2000s TypePad and
hand-built blog layouts. It keeps the era's blogrolls, categories, metadata,
and generous serif headings while using Boris's graph-backed navigation.

This is a static theme example, not a WordPress or TypePad importer. It has no
JavaScript, CDN, framework, or remote image dependency. Dynamic services such
as comments and TrackBacks are represented as authored metadata or explicit
static review notes.

## Build

```bash
./zig-out/bin/boris \
  --input examples/agent-themes/cozy-corner/content \
  --theme examples/agent-themes/cozy-corner/theme \
  --html-dir test-output/cozy-corner \
  --quiet
```

The index Trunk owns the blogroll-style sidebar and direct child posts. Each
post is a Satellite linked with `parent: index`. The local SVG is published
through the normal content-local asset path.
