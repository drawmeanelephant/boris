# Changelog — `boris-docs-maintenance`

All notable changes to the standalone `boris-docs-maintenance` developer tool will be documented in this file.

## [Unreleased]

### Added
- Initial release of the standalone documentation maintenance developer tool (`tools/docs-maintenance/`).
- Deterministic scanner for inventorying evidence sets, parsing `BORIS-SOURCE-DOC` markers, and computing evidence digests.
- Output report generators for `boris-docs-inventory-v0` JSON and Markdown summary.
- Comprehensive fixture test suite in `src/scanner_test.zig`.
