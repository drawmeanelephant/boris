### Added

- The editor host's preview state (`GET /api/preview/state` and a `200` from
  `POST /api/preview/rebuild`) carries an additive `stale_reason` —
  `earlier_build` when `dist/` was already on disk at startup, `failed_rebuild`
  when a rebuild failed, timed out, or could not run and the last valid tree was
  kept, and `null` whenever `phase` is not `stale` — so the shell no longer
  infers a startup warning from a failed rebuild's `exit_code`. Older hosts
  without the field keep the `exit_code` fallback. Links:
  [the editor-host contract](/docs/contracts/editor-host.md#82-fixed-rebuild-command),
  [issue #1068](https://github.com/drawmeanelephant/boris/issues/1068).
