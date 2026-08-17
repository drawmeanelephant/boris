### Fixed

- Watch mode now treats graph-validation failures (`error.GraphValidationFailed`
  — duplicate ids, missing/self/cyclic parents, and other hard topology
  errors) as recoverable content failures, matching `ParseFailed`: the watcher
  stays alive for author correction, preserves the previously valid published
  output, and recovers in the same process session instead of exiting. Links:
  [watch-mode contract](/docs/contracts/watch-mode.md),
  [#640](https://github.com/drawmeanelephant/boris/issues/640).
