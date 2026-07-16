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
nested Boris-mediated includes, wiki-links, and a layout. The reported elapsed
time covers only the Boris child process. The harness owns
`tools/scale-smoke/.generated/`, recreates it for each run, and removes it on
success or failure. It does not clean any other path.

Use `--help` for the complete command surface.
