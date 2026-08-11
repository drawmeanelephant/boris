# Boris deterministic benchmark corpus generator

Part of PERF-028 (issue #324): a checked-in, deterministic corpus generator for
the Boris HTML benchmark and CI regression gate.

It is deliberately **not** an authority for production content: it synthesizes
a valid Boris input tree below an owned output directory (default
`.generated/`), recreates it on every run, and removes it on success or
failure. The same `--pages` value always produces byte-identical trees
(enforced by unit tests).

The generated tree exercises the HTML costs the 2026-08-11 optimization audit
found:

- a **nav-consuming layout** — `{{nav}}` renders the full site forest on every
  page, so per-page output is proportional to site size (the intentional
  per-page navigation cliff);
- Trunk/Satellite parent relations;
- nested Boris-mediated includes (`{{include includes/common.md}}` →
  `{{include includes/shared.md}}`);
- wiki-links (`[[index]]`, `[[sections/section-NNNN]]`);
- several headings per page so heading harvest does real work.

## Usage

```bash
# Build Boris first (any mode; the benchmark step builds its own ReleaseFast binary)
zig build

# Generate a 1k-page corpus below tools/testdata-generator/.generated
zig run tools/testdata-generator/main.zig -- --pages 1000

# Larger trees are supported (exact page counts, e.g. 5k)
zig run tools/testdata-generator/main.zig -- --pages 5000 --out .tmp/corpus-5k

zig run tools/testdata-generator/main.zig -- --help
```

`--out` is an owned path: it must be relative to the current working
directory, contain no `.` or `..` segment, and have no trailing separator.
The generator rejects unsafe paths before deleting anything.

## Tests

```bash
zig test tools/testdata-generator/main.zig
```

Covers exact page counts, argument validation, the nav-consuming layout, and
the byte-identical determinism contract. The suite is also wired into
`zig build test`.

## Baseline and gate

The pinned 1k-page baseline lives at
`baseline/benchmark-1k.json` and the gate lives in
[`scripts/benchmark.sh`](../../scripts/benchmark.sh), invoked by
`zig build benchmark` (ReleaseFast-only). To refresh the baseline after a
deliberate, verified change (maintainer action):

```bash
BORIS_BENCHMARK_UPDATE_BASELINE=1 zig build benchmark
```

Then commit the rewritten `baseline/benchmark-1k.json`. Never refresh from an
unexplained slowdown — that is exactly what the gate exists to catch. The
checked-in baseline is a conservative cross-platform floor: compare supported
host classes and retain the slower verified value for each phase.
