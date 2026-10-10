### Fixed

- The editor preview can no longer stick on `running`: a Boris process that
  exits `0` without producing `dist/index.html` now lands the preview on
  `failed` with a message naming the missing output, and the shell re-reads
  `/api/preview/state` after any refused or failed rebuild response so the
  Rebuild preview action stays usable. Links:
  [the editor host contract](/docs/contracts/editor-host.md),
  [#1073](https://github.com/drawmeanelephant/boris/issues/1073).
