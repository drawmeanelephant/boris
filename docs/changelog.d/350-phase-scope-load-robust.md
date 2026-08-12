### Fixed

- The `--timings` phase-scope regression tests no longer flip under CPU
  contention on parallel CI runners. The sum-overlaps-wall-time bound (the
  primary overlap detector) is checked per-run and is load-invariant — disjoint
  scoped phases on one monotonic clock can never sum above the measured span —
  while the phase-vs-phase bounds are asserted on per-phase minima across five
  runs, which are the uncontended estimates (descheduling only inflates a
  wall-clock phase, and a deterministic overlap inflates every run and still
  fails). No sleeps, retries, or machine-specific tolerances.
