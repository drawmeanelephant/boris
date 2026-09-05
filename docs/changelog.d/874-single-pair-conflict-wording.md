### Fixed

- Single-cause conflicting-options rejections now name both tokens as typed per the #764 rule: `boris plan --profile p.json --timings` reports `plan conflicts with --timings`, `validate`/`check`/`impact --profile` name the mode (`validate conflicts with --profile`), and flag×flag pairs name both flags (`--watch conflicts with --profile`) instead of the generic `conflicting options (try --help)`. Multi-cause argv keeps the generic form; exit code 2 is unchanged. Links: [the CLI contract](/docs/contracts/cli.md), [#874](https://github.com/drawmeanelephant/boris/issues/874).
