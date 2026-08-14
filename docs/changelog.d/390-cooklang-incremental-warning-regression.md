### Changed

- New black-box regression step `test-cooklang-incremental-warnings` (part of
  `zig build test`) pins the warning-printing contract: Cooklang structural
  warnings print exactly once on the plain HTML, IR, and incremental HTML
  paths — including the no-change incremental rebuild whose cache-reused pages
  skip render entirely. See
  [`scripts/test-cooklang-incremental-warnings.sh`](/scripts/test-cooklang-incremental-warnings.sh).
