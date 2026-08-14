### Fixed

- `boris validate` now runs the output link audit in memory over the exact
  assembled page bytes, so `EROUTEMISSING`, `EROUTEESCAPE`, and
  `EPUBLICATIONLOCATION` fail validation exactly as they fail compilation —
  previously `validate` let broken local links and publication-location
  escapes pass silently while remaining write-free. The audit reuses the
  shared render/splice path and the same diagnostics reporter as `build`
  (issue #430), and the validation contract now documents the in-memory
  audit surface.
