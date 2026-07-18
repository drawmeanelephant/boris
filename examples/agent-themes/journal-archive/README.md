# Journal archive theme

An offline-first Boris theme for terminal diaries, personal journals, and
early-web archives. It borrows the visual language of the fearless-salk
prototype—black paper, phosphor green, hard borders, monospace type—while
using Boris's graph-backed page relationships for the archive index.

This is a static theme example, not a LiveJournal clone or a new product
feature. It has no JavaScript, CDN, framework, or runtime dependency.

## Build

From the repository root, after `zig build`:

```bash
./zig-out/bin/boris \
  --input examples/agent-themes/journal-archive/content \
  --theme examples/agent-themes/journal-archive/theme \
  --html-dir test-output/journal-archive \
  --quiet
```

The landing page is the Trunk. Chronological entries are Satellites linked by
`parent: index`; `{{children}}` renders their deterministic archive list.

## Design decisions

- Dates, mood, music, and tags are ordinary authored Markdown so they remain
  portable during migration.
- The userpic is represented as an accessible text block until a real local
  asset is supplied.
- Unsupported dynamic journal features such as comments, reactions, and live
  presence are intentionally absent: a static conversion should document those
  boundaries rather than pretend to preserve them.

Generated output belongs under ignored `test-output/` and is not committed.
