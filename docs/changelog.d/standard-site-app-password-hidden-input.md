### Changed

- `standard-site login --app-password` now suppresses terminal echo while the
  app password is typed, restoring the terminal attributes even on failure, so
  the credential never lands in scrollback. Interactive input reads exactly
  one line; piped secret files still read to end of stream, and empty input is
  rejected on both paths.
