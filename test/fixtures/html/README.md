# HTML path fixtures (milestone 9)

Experimental HTML compile goldens for `src/compile.zig` / `src/assemble.zig`.

```text
content/           # markdown inputs
layouts/main.html  # single {{content}} marker
expected/          # published HTML after layout splice + Apex body render
```

Run via `zig build test` (`html fixture golden` in `src/compile.zig`).

Not the default `boris` CLI surface — see `docs/contracts/html-output.md`.
