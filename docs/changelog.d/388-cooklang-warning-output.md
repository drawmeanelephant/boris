### Changed

- Cooklang structural warnings (an unclosed `{`, `(`, or `[-`) print exactly
  once on the HTML path instead of twice: the load-time validation pass — the
  only pass that runs once per build and covers every page, including the
  cache-reused pages an incremental build skips at render time — is the only
  printer. The exact stderr for both the pipeline and HTML paths is now pinned
  in [the Cooklang compatibility contract](/docs/contracts/cooklang-compatibility.md),
  including the real Oliver code for an unclosed preparation
  (`unclosed-preparation`, not the previously documented `unclosed-paren`) and
  the rule that a bare `(` in prose is not a construct and stays silent.
