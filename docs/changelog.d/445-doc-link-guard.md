### Added

- Added a `zig build test-doc-links` guard inside `zig build test`: every
  relative Markdown link in `README.md` and the
  [authoring spine](/docs/authoring-spine.md) must resolve to a real file
  or directory, heading anchors must match GitHub-style slugs, and the
  spine must keep its six-step shape. The first run caught the README's
  phantom `benchmark/` link; the Benchmarking section now states honestly
  that no committed benchmark harness exists yet.
