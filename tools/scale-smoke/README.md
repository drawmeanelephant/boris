# Boris scale smoke

This is an opt-in, synthetic scale smoke harness. It is intentionally not a
build step or CI gate.

From the repository root, build Boris, then run the Zig harness:

```bash
zig build
zig run tools/scale-smoke/main.zig -- --pages 100 --boris ./zig-out/bin/boris
```

`--pages` is the exact number of discovered pages; the default is `100`. The
same deterministic generator supports a larger local smoke when wanted:

```bash
zig run tools/scale-smoke/main.zig -- --pages 10000 --boris ./zig-out/bin/boris
```

Each generated site has Trunk and Satellite pages, valid `parent` references,
nested Boris-mediated includes, wiki-links, and a layout. The harness generates
the input once, then performs repeated cold builds for `-j1` and `-j8` by
deleting only the prior output tree before each sample. Cleanup time is reported
separately; compile timing begins after deletion. It records OS, CPU model when
available, core count, Zig version, the caller-supplied optimization label,
worker count, input/output bytes, output-tree SHA-256, and peak RSS when the
host's local timing wrapper exposes it. Every digest must match within a worker
setting for the run to be marked deterministic.

Example with an explicit optimization label and report destination:

```bash
zig run tools/scale-smoke/main.zig -- \
  --pages 100 --runs 3 --jobs 1 --jobs 8 \
  --optimize Debug --boris ./zig-out/bin/boris \
  --report BENCHMARK-REPORT.md
```

The report's arithmetic means are within-run observations only. Cross-machine
timings and RSS are non-comparable unless the recorded environment, input
bytes, optimization mode, and worker settings match. The harness owns
`tools/scale-smoke/.generated/`, recreates it for each run, and removes it on
success or failure. It does not clean any other path.

Use `--help` for the complete command surface.
