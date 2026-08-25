# Changelog

All notable changes to Boris are documented here.

Format inspired by [Keep a Changelog](https://keepachangelog.com/).
Versioning: the current product cut is **v0.8.1 candidate** with base IR
`schemaVersion` **`0.2.0`** and compiler id **`boris/0.8.1`**. Breaking IR
changes must bump `schemaVersion` and update `docs/contracts/`. Product version
bumps may update `compiler_id` / `boris_version` without changing IR schema.
The historical `v0.8.0` tag is preserved as erroneous evidence; see
[`docs/STATUS.md`](docs/STATUS.md).

How to use going forward:

- Feature/fix PRs add one fragment under
  [`docs/changelog.d/`](docs/changelog.d/README.md); do not edit the shared
  **`[Unreleased]`** section.
- At release cut, the release owner assembles the fragments into a dated section,
  in the documented deterministic order, then removes or archives them and resets
  Unreleased.
- Prefer one short bullet per user-visible or contract-visible change.
- Each fragment includes at least one repository-root-relative Markdown link;
  link the relevant contract when the IR or acceptance surface moves.

---

## [Unreleased]

Queued release inputs remain under
[`docs/changelog.d/`](docs/changelog.d/README.md) and will be assembled into
this section by the release owner at release cut.

## [0.8.0] — 2026-07-21

The v0.8.0 release keeps base IR `0.2.0` and conditional semantic-relation IR
`0.3.0`; it packages post-v0.7 release hardening, migration review tooling,
source-RAG upload ergonomics, and the ApexMarkdown v1.1.12 vendor update.

### Added

- Added deterministic whole-file source-RAG bundle partitioning with
  `--split-size`, ordered `part_manifest.json` provenance, and documented
  oversized-file and `--no-bundles` behavior. See the
  [source-RAG guide](/tools/source-rag/README.md).
- Added `boris-source-rag --bundles-only` plus `upload_manifest.json` for
  combined upload bundles without the per-file `files/**` tree. See the
  [source-RAG guide](/tools/source-rag/README.md).
- Added deterministic, review-first Astro/Starlight relationship candidate
  extraction with source provenance and explicit product-bound evidence. See
  the [migration-lab guide](/tools/migration-lab/README.md).
- Added migration-lab `frontmatter-review` mode for preserving unknown source
  frontmatter as an explicit review report without widening Boris core grammar.
  See the [migration-lab README](/tools/migration-lab/README.md).

### Changed

- Upgraded the vendored ApexMarkdown Unified engine to upstream `v1.1.12` with
  identical Boris HTML, Aside, RAG, diagnostics, and ABI behavior on the
  representative gates. See [`vendor/apex-markdown/VENDOR.md`](vendor/apex-markdown/VENDOR.md).

### Fixed

- Package archive publish no longer deletes the live tar before the replacement
  is complete; install uses move-aside so a failed write preserves any previous
  archive. See the [package module](/src/package.zig).
- Fixed Starlight migration matching so prefix-colliding components such as
  `<Asides />` remain explicit manual-review fallbacks instead of producing
  unterminated Boris [`<Aside>` blocks](/docs/contracts/components.md).
- Hardened [`theme-materialize`](/tools/migration-lab/README.md) so static
  assets with companion remote or traversal evidence in an archaeology ledger
  are refused rather than copied into a Boris theme draft.

### Docs

- Added and updated real-site Filed.fyi, WordPress Theme Test Data, Starlight,
  agent roll-call, contest homepage, link-audit, and release-honesty evidence
  while keeping migration labs bounded developer aids.
- Clarified bounded [`--jobs` HTML workers](/docs/contracts/parallel-rendering.md),
  sanitizer evidence, frontmatter `relations`, and current release status.

---

Full history before v0.8.0: see [archived changelog](docs/archived/CHANGELOG-pre-0.8.md).
