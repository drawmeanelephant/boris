<!--
Filename: <pr-number>-<short-kebab-case-summary>.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Changed

- Product RAG is now a retrieval/working-context projection: the default
  `--rag` export produces a small set of bounded `working-N.md` upload packs
  containing complete, verbatim **site** documents (frontmatter, H1s, and
  `<Aside>` / `<Details>` syntax preserved) plus a `manifest.json` sidecar that
  is not meant for upload, and `--rag --complete` is the explicit full-corpus
  export; RAG schema bumps to `2`. See the
  [RAG export contract](/docs/contracts/rag-export.md).

### Merge-readiness pass

- **Working packs are site-only.** Default working mode carries the selected
  site documents and required site graph closure — never the `docs/rag/system`
  corpus, scoped or unscoped. System seeds remain in explicit `--complete`
  exports only.
- **Working mode emits exactly two shapes of file:** the `working-N.md` packs
  and `manifest.json`. `catalog_meta.json` is complete-mode surface only; the
  manifest already records format, schema version, and Boris version. The CLI
  summary now lists the exact upload file paths and identifies `manifest.json`
  separately as a non-upload sidecar.
- **`--complete` means complete.** Combining `--complete` with `--scope` is a
  CLI usage error (exit 2); the scoped tree-shaped export remains available on
  the working surface (`--rag --scope`), which also covers pre-v2
  scoped-bundle workflows.
- **Complete-mode catalog is self-consistent.** `INDEX.md` is itself a catalog
  row, appended before sorting/counting, so INDEX's catalog count and
  full-catalog table equal the `catalog.jsonl` row count.
- **Role accounting precedence.** A page that is both a structural ancestor
  and a semantic-relation target counts as structural context; reported
  precedence is requested → structural ancestor → semantic-only neighbor.
- **Pack boundaries are unambiguous by construction.** A source line beginning
  with the `<!-- boris-rag-doc:` marker prefix fails the export
  (`SeparatorCollision`) instead of producing an ambiguous pack.
- **Textile fidelity is stated precisely.** Textile input is deterministically
  adapted to Boris-authorable Markdown; Markdown input remains verbatim.
  Documents no longer claim byte-for-byte fidelity for Textile input.

### Measurements (representative fixture: `fixtures/content/valid` + `docs/rag/system`)

| Metric | Before | After |
|---|---|---|
| Selected site documents (working) | 8 | 8 |
| Working upload file count | 1 | 1 |
| Working upload bytes / approximate tokens | 48,025 / 12,006 | 2,158 / 539 |
| Non-upload sidecar count (working) | 2 | 1 |
| System seed count in working mode | 11 | 0 |
| Complete-mode file count / catalog entries | 25 files / 23 `catalog.jsonl` rows (INDEX count said 22) | 25 files / 23 rows (INDEX count now 23, matching `catalog.jsonl`) |
