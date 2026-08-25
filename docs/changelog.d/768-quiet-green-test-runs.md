<!--
Filename: 768-quiet-green-test-runs.md
-->

### Fixed

- `zig build test` green runs no longer print phantom `failed command:` failure
  blocks: expected negative-path diagnostic prose is suppressed in unit-test
  binaries (the Zig build runner echoes a passing test binary's captured stderr
  as if the step had failed), while CLI `--quiet` semantics and watch-json
  suppression are unchanged. A new `test-quiet-pass` guard keeps the echo from
  regressing. See [src/diag.zig](/src/diag.zig) and
  [#768](https://github.com/drawmeanelephant/boris/issues/768).
