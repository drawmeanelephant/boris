### Fixed

- `boris --help` no longer prints a stray backslash on the `recipe-scale` mode
  line — a doubled multiline marker that shipped because nothing read the help
  text, which is now a named constant with a test over its shape — and the
  interactive CLI reference documents the three shipped commands it was missing
  (`graph`, `proof verify`, and `init`) instead of describing a
  six-command surface. Links: [the command
  reference](/content/reference/commands.md), [the CLI
  contract](/docs/contracts/cli.md).
