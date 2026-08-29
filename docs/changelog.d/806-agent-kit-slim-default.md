<!-- Filename: 806-agent-kit-slim-default.md -->

### Changed

- Agent binary kits now default to the root product CLIs (`boris`,
  `boris-package`, `boris-source-rag`); standalone developer tools are opt-in
  via `scripts/agent-pack.sh --all-tools`, and the kit README names the
  built-in `boris watch --serve` / `--watch-json` feedback loop. Links:
  [the agent binary kit guide](/docs/AGENT-BINARY-KITS.md).
