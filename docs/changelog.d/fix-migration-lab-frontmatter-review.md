## fix(migration-lab): complete frontmatter-review integration

- Wired [`frontmatter_review.zig`](/tools/migration-lab/frontmatter_review.zig)
  into the migration-lab build and CLI as `--mode=frontmatter-review`
  (aliases: `fm-review`, `fmreview`); new `--content=DIR` flag implies the
  mode (mirrors the pattern of `--wxr`, `--vault`, `--dump`, etc.).
- Added `Options.content_dir` field and complete `parseOptions` coverage with
  four new CLI tests for flag forms, alias resolution, and mode inference.
- Added `_ = frontmatter_review` to the main-module `test {}` block so all
  unit and fixture tests in `frontmatter_review.zig` run under
  `zig build --build-file tools/migration-lab/build.zig test`.
- Enforced strict closing-fence detection in `scanFile`: the `\n---` token
  must be followed by EOF, LF, or CRLF; a mid-value `---` substring no
  longer falsely closes the fence.
- Added `escapeMdCell` helper in `frontmatter_review.zig`: escapes `|` as
  `\|` and collapses newlines to spaces so Markdown table rows stay
  single-line; wired into `emitMd` for both `key` and `value` columns.
- Added three `escapeMdCell` unit tests and one `emitMd` pipe-escape
  integration test.
- Boris core (`src/`), IR contracts, and all previously converted content
  are not modified.

Links: [migration-lab README](/tools/migration-lab/README.md),
[frontmatter contract](/docs/contracts/frontmatter.md).
