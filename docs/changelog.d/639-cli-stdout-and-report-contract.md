### Docs

- The CLI contract now specifies the stdout machine surface — the closed set of
  commands/flags that emit one document on stdout (`--version`, `--timings`,
  `plan`, `standard-site plan|records|verify|publish|smoke`,
  `nostr plan|sign|publish`, `recipe-scale`) and the empty-stdout rule for
  everything else — and documents per-mode `--report` semantics, fixing the
  misleading `--help` text that claimed `--report` wrote "instead of stdout".
  Links: [CLI contract](/docs/contracts/cli.md),
  [diagnostics](/docs/contracts/diagnostics.md),
  [#639](https://github.com/drawmeanelephant/boris/issues/639).
