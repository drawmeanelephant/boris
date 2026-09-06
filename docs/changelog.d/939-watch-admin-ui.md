### Added

- The editor UI gains a Watch pane for the managed watch daemon: honest
  idle/running/success/failed/stale state naming, a bounded newest-first feed
  of the compiler's `--watch-json` build events with ring-eviction boundaries
  labeled, explicit Start/Stop controls plus command-palette entries, a
  preview-rebuild refusal note when the daemon owns the `dist/` writer seat,
  and an honest "not supported" notice against hosts without the backend —
  see [the editor README](/editor/README.md) and
  [the watch-mode contract](/docs/contracts/watch-mode.md).
