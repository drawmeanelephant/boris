### Changed

- `boris-testdata run` and `republish-clean` now accept `--jobs N` (default `1`, valid range `1..64` matching Boris; both `--jobs N` and `--jobs=N` forms are accepted) and pass the requested worker upper bound to Boris as `--jobs N`. Zero, out-of-range, empty, malformed, duplicate, and missing values are rejected deterministically, and `generate`, `validate`, and `inspect` reject `--jobs` as a usage error.
- Run evidence moved to `boris-testdata-run/5` with a structured `execution.requestedJobs` record and no longer repeats the legacy flat `artifactInventorySha256`/`artifactInventoryFileCount` and `outputSnapshotSha256`/`outputSnapshotFileCount` fields. `republish-clean` evidence moved to `boris-testdata-republish-clean/2` with the same structured worker request.
- Added determinism tests proving publication bytes and recorded evidence are identical across worker counts (jobs 1/4/8), including a normalization helper that replaces only `execution.requestedJobs` before comparing parsed evidence.

### Hardened

- `generator.runFixture` and `generator.republishCleanFixture` now validate the requested worker bound through a shared `generator.validateJobs` before deleting output trees, spawning Boris, or writing evidence; out-of-range values return `error.InvalidJobs`. The CLI parser delegates to the same validator.
- The Boris subprocess argument vector is constructed by the shared `generator.buildBorisInvocation` helper, and tests assert the exact `--html-dir <path> --jobs <decimal requested value> --quiet` sequence for jobs 1, 4, and 64 plus that the recorded evidence value equals the value placed in the vector.
- `-h`/`--help` genuinely wins regardless of argument position or malformed/missing `--jobs` values; the parser honors help before validating anything else.
