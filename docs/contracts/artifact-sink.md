# Artifact sink

**Status:** normative for [#301](https://github.com/drawmeanelephant/boris/issues/301) M2  
**Module:** [`src/artifact_sink.zig`](../../src/artifact_sink.zig)  
**Related:** [json-ir-and-manifest.md](json-ir-and-manifest.md), [publication-artifacts.md](publication-artifacts.md), [source-provider.md](source-provider.md)

The compiler leaves bytes through one operation: **emit** a named artifact
(`path`, `media_type`, `bytes`). This does not change the IR or publication
inventory schemas. It is how those bytes leave the compiler.

## Adapters

| Adapter | Role |
|---|---|
| `Dir` | Native CLI default. Collects the batch, then stage+rename into `out_dir` exactly as the IR publisher already did. |
| `Memory` | Embedding / tests. Collects records. No host output directory. |

`pipeline.run` uses `Dir` when `Options.sink` is null.

## Path rules

Artifact paths are output-relative, `/` separated, and fail closed on:

- empty path
- absolute path
- `.` or `..` segments
- duplicate emit of the same path

## Failure policy

Unchanged from the IR publisher: a failed compile emits only
`build-report.json`. Graph-dependent files (`manifest.json`, `graph.json`,
`completion.json`) are not emitted. The `Dir` adapter still removes any
prior copies of those files from `out_dir`.

## What this does not cover

HTML, theme assets, checks, claims, Touch Atlas, and Proof Pack stay on
their existing writers until later #301 cards. `publication-artifacts.md`
is unchanged.
