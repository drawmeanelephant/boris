# HTML path fixtures (milestone 9)

Experimental HTML compile goldens for `src/compile.zig` / `src/assemble.zig`.

```text
content/           # markdown inputs
layouts/main.html  # single {{content}} marker
expected/          # published HTML after layout splice + Apex body render
```

Run via `zig build test` (`html fixture golden` in `src/compile.zig`).

Used by the default HTML CLI path — see `docs/contracts/html-output.md`.
