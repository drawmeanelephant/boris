<!--
Filename: <pr-number>-<short-kebab-case-summary>.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Changed

- Product RAG is now a retrieval/working-context projection: the default
  `--rag` export produces a small set of bounded `working-N.md` upload packs
  containing complete, verbatim authoring documents (frontmatter, H1s, and
  `<Aside>` / `<Details>` syntax preserved) plus a `manifest.json` sidecar that
  is not meant for upload, and `--rag --complete` is the explicit full-corpus
  export; RAG schema bumps to `2`. See the
  [RAG export contract](/docs/contracts/rag-export.md).
