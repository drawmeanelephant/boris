### Fixed

- Full rebuilds no longer delete declared `--static-dir` `.html` passthrough files: the stale-output walker now skips currently-declared static paths (stale entries are still scrubbed), so declared embeds survive and `artifact-integrity` passes ([html-output](/docs/contracts/html-output.md), #866).
