<!--
Filename: 309-content-audit-repro-and-policy-gaps.md (pr-number is the real PR number)
Keep exactly one category heading.
-->

### Fixed

- [`boris-content-audit`](/tools/content-audit/) closes the last two
  qualification gaps: density-band values must fit `u32` (a value above
  `4294967295` is a malformed policy, exit 4, instead of trapping or
  truncating), and every caller-controlled value in the reproduction command
  (`--content-root`, `--revision`, `--collection`, format, fail-on) is emitted
  with shell-safe argument boundaries — values with spaces, quotes, or shell
  metacharacters are single-quoted so each survives as exactly one argument in
  a POSIX shell, while plain values stay byte-identical.
