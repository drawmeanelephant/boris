# Filed build benchmark harness

This directory contains only the reproducible runner. It compares explicit
checkouts when available: a pinned historical Astro 6.x checkout, a current
Astro 7.x checkout, and the Boris checkout/build used for Filed. The runner
never invents a version or changes a source checkout.

Scenarios:

* **A** — cold build; output and cache are removed before every sample.
* **B** — warm build; output/cache are removed once and retained across samples.
* **C** — incremental no-op; unchanged source and retained state are rebuilt.
* **D** — incremental one-page edit; an unmeasured baseline and deterministic
  edit precede each measured incremental build.

Every scenario must be configured for every listed implementation. Missing
configuration is an error. If Astro 7 is genuinely unavailable, remove it
from `BENCHMARK_IMPLEMENTATIONS` and record `ASTRO7_UNAVAILABLE_REASON`; the
runner will then produce an explicit two-implementation run rather than a
fabricated version or silent skip.

## Configuration and phases

Copy the template to a private file, fill every value, and run setup separately
from measured builds:

```bash
cp benchmark/environment.txt /tmp/filed-benchmark.env
$EDITOR /tmp/filed-benchmark.env
benchmark/run-benchmarks.sh --env /tmp/filed-benchmark.env setup
benchmark/run-benchmarks.sh --env /tmp/filed-benchmark.env --runs 10 run
```

Commands run from each implementation checkout and may use the exported
`BENCHMARK_SOURCE_DIR`, `BENCHMARK_OUTPUT_DIR`, `BENCHMARK_CACHE_DIR`, and
`BENCHMARK_RUN_DIR`. They must write only to those configured output/cache
paths. D baseline/edit commands are unmeasured and captured under `work/`.

The runner verifies that every implementation is a Git checkout and that
`*_REF` resolves exactly to `HEAD`. It records commit, package manifest hash,
Astro dependency declaration, host, and checkout status in an environment
manifest. `benchmark/raw/` receives untouched child stdout/stderr for every
sample. `results.tsv` records exit code, elapsed time, peak RSS where
`/usr/bin/time` supports it, and output file count/bytes.

Use the TSV as input to the separately owned report generator. The headline
statistic is median elapsed time; preserve min, max, arithmetic mean, and
population standard deviation in that report. Generated work trees, manifests,
raw logs, and reports should remain untracked unless repository convention
explicitly says otherwise.

## Smoke test

Configure three tiny local Git checkouts and commands that create one output
file, then run one repetition to validate the matrix and raw capture:

```bash
benchmark/run-benchmarks.sh --env /tmp/filed-benchmark-smoke.env --runs 1 run
test "$(find /tmp/filed-benchmark-artifacts/raw -type f | wc -l | tr -d ' ')" -eq 24
```

This smoke test is not benchmark evidence.
