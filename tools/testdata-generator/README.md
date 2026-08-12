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

`--dense-links N` (PERF-013, issue #331) additionally writes N wiki-links to
other pages on every generated page, deterministically (targets are the next N
generation positions, wrapping, never self). `--dense-links N-1` on an N-page
tree makes every page link to every other page — the old O(links × pages)
per-hit page scan worst case — so the `dependency_resolve` phase can be
measured on dense link sets. `--fragment-links N` (PERF-021, issue #336)
writes N wiki *fragment* links (`[[entity#overview]]`) to other pages on every
generated page, deterministically and never self; the `overview` fragment
exists on every generated page, so the tree builds clean and every referenced
page becomes a heading-harvest fragment target. Both link modes can be
combined. With `--dense-links 0 --fragment-links 0` (the default) the corpus
is byte-identical to previous versions.

## Usage

```bash
# Build Boris first (any mode; the benchmark step builds its own ReleaseFast binary)
zig build

# Generate a 1k-page corpus below tools/testdata-generator/.generated
zig run tools/testdata-generator/main.zig -- --pages 1000

# Larger trees are supported (exact page counts, e.g. 5k)
zig run tools/testdata-generator/main.zig -- --pages 5000 --out .tmp/corpus-5k

# Dense-link corpus: every page links to the next 20 pages
zig run tools/testdata-generator/main.zig -- --pages 1000 --dense-links 20

# Full density: every page links to every other page (N-1 links per page)
zig run tools/testdata-generator/main.zig -- --pages 1000 --dense-links 999

# Fragment-link corpus: every page targets the next 20 pages' ## Overview heading
zig run tools/testdata-generator/main.zig -- --pages 1000 --fragment-links 20

zig run tools/testdata-generator/main.zig -- --help
```

`--out` is an owned path: it must be relative to the current working
directory, contain no `.` or `..` segment, have no trailing separator, and
pass through no existing symlink component. The generator rejects unsafe paths
before deleting anything, and cleanup is anchored through no-follow directory
handles so a concurrent path-component swap cannot redirect recursive deletion.

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
