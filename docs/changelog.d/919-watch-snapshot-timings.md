### Fixed

- `boris watch` survives transient filesystem hiccups: a root scan failure keeps the previous snapshot and emits no events instead of firing a mass-delete rebuild storm that kills the watcher (#876).
- `boris watch --timings` now records phase/counter data for initial and rebuild compiles, so the shutdown report carries real measurements instead of an all-zero artifact ([watch-mode](/docs/contracts/watch-mode.md), #877).
