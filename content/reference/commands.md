---
title: Command Reference
parent: reference
status: published
tags: [reference, cli]
---

# Command Reference

Use `boris` with no command for the normal HTML build. The explicit `build`
spelling does the same thing; `check`, `impact`, and `watch` cover the other
day-to-day jobs.

## Build a site

```bash
./zig-out/bin/boris
./zig-out/bin/boris build
./zig-out/bin/boris --input my-docs --html-dir public
```

The default build reads `content/` and writes HTML to `dist/`. It validates the
whole page graph before publishing, so a broken parent, include, or wiki-link
does not become a partially navigable site.

| Need | Command |
|---|---|
| Faster repeat build | `boris --incremental` |
| Rebuild while authoring | `boris watch` |
| Render independent pages concurrently | `boris --jobs 4` |
| Select an HTML destination | `boris --html-dir public` |
| Build named isolated destinations | `boris --target prod=dist/prod --target preview=dist/preview` |

`watch` is HTML-only and implies incremental mode. `--jobs` is bounded page
rendering; discovery and graph validation still run as a deterministic
coordinator phase.

## Inspect a graph without publishing

```bash
./zig-out/bin/boris check
./zig-out/bin/boris check --input my-docs --format json --report health.json
./zig-out/bin/boris impact guides/overview
```

`check` validates the frozen graph and reports policy findings. `impact ID`
lists transitive dependents for a page or source endpoint. Both commands are
read-only unless you explicitly supply `--report`.

## Choose a machine output deliberately

```bash
./zig-out/bin/boris --out .boris       # JSON IR
./zig-out/bin/boris --rag              # RAG corpus
./zig-out/bin/boris --context          # AI Context Bundle
./zig-out/bin/boris --llms             # llms.txt map
```

These are separate output modes, not add-ons to an HTML build. In particular,
`--out` selects the JSON IR path; it does not also write `dist/`. See
[[reference/outputs|Outputs and Artifacts]] for the artifact shapes and
[[guides/cli-and-modes|CLI and Run Modes]] for a quick tour.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Successful command |
| `1` | Content or graph problem (or a `check` policy finding) |
| `2` | Invalid command or option combination |
| `3` | I/O or system problem |

Run `boris --help` for the complete flags. It exits successfully without
reading content or writing files.
