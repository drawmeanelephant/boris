<!--
Filename: watch-admin.md (placeholder; the orchestrator renames it to the PR number)
Keep exactly one category heading.
-->

### Added

- The editor host now supervises one managed `boris watch --watch-json` daemon
  per project: authenticated start/stop/state/event endpoints surface the
  compiler's contracted NDJSON build-event stream with monotonically
  increasing sequence numbers, rebuilds are refused while the daemon owns the
  `dist/` writer seat, and stopping the daemon (or the host) always reaps it.
  An explicit stop also clears any crash residue, so the post-stop state reads
  `idle` with no stale `last_error`.
  See [the editor README](/editor/README.md) and
  [the watch-mode contract](/docs/contracts/watch-mode.md).
