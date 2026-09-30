## Added

- `boris build --profile` and `boris watch --profile --serve` now execute supported declared HTML targets without repeated layout/theme/static flags, using the profile workspace and the existing compiler/watch pipeline; validation shares the mapping, static-file links participate in both output audits, and unsupported declarations fail before subset publication. See [the profile execution contract](/docs/contracts/publication-profile.md#html-execution).
