# Release gate — Boris v0.8.1 candidate

Mechanical checklist before tagging a release or claiming a milestone complete.
This documents the gate for the **v0.8.1 candidate**. The historical v0.8.0
tag remains preserved as erroneous evidence; do not re-tag prior releases.

Run locally:

```bash
zig build
zig build test
zig build test-validation
zig build test-render
zig build run -- --input fixtures/content/valid --out .tmp/boris-ir
zig build run -- --input fixtures/content/valid --rag-dir .tmp/boris-rag
zig build run -- --input test/fixtures/html/content --html-dir .tmp/boris-dist
zig build run -- --input content --quiet   # default HTML → dist/
zig build package              # optional; review tar under packages/ (not ship-blocking)
./scripts/release-gate.sh      # preferred one-shot mechanical gate
./scripts/test-release-gate-git-detection.sh  # step 7 worktree detection smoke
```

Step **7** (no tracked/disallowed generated product output) detects a real Git
checkout with `git rev-parse --is-inside-work-tree`, not `[[ -d .git ]]`. Linked
worktrees store `.git` as a file (gitdir pointer); the directory check would
skip cleanliness there. The approved/generated path policy is unchanged.
`./scripts/test-release-gate-git-detection.sh` creates a temporary linked
worktree and asserts the Git-native predicate still enables the check.

CI (`.github/workflows/ci.yml`) pins **Zig 0.16.0** and runs `zig build`,
`zig build test`, and `zig build test-render` on `ubuntu-latest` and
`macos-latest`. The root aggregate deliberately excludes standalone tools;
changes under `tools/migration-lab/` additionally run its Linux-only targeted
gate, while changes under `tools/search-index/`, `tools/docs-maintenance/`, or
the shared `src/search_index.zig` run both standalone tool gates on Ubuntu and
macOS:

```bash
zig build --build-file tools/migration-lab/build.zig test
zig build --build-file tools/search-index/build.zig test
zig build --build-file tools/docs-maintenance/build.zig test
```
## Checklist

Items stay unchecked until the corresponding work is implemented **and**
verified. Do not check an item because a design doc exists.

- [x] **Build configuration** — reproducible `build.zig` / `build.zig.zon`,
      executable name `boris`, Zig 0.16.0 pin aligned across package metadata
      and CI
- [x] **Scanner / parser tests** — discovery and frontmatter grammar covered by
      automated tests against fixtures (`src/scanner.zig`, `src/parser.zig`)
- [x] **Graph tests** — Trunk / Satellite parent validation (missing parent,
      cycles, duplicates, role rules) covered by tests (`src/graph.zig` +
      pipeline integration fixtures)
- [x] **Authoritative no-publication validation** — `boris validate` reuses the
      HTML compiler's source/graph/dependency/render preflight, preserves
      canonical diagnostics, and leaves new and existing targets untouched
      (`zig build test-validation`; contract
      [`validation.md`](contracts/validation.md))
- [x] **Deterministic IR test** — JSON IR emit is byte-stable across dual runs
      on the same host (pipeline dual-export diff of `manifest.json` /
      `graph.json`); the F8 fixture pins typed parent/include/reference edges
      and `reverseIndex`
- [x] **RAG determinism test** — dual RAG export to distinct dirs is
      byte-identical (`src/rag.zig` full-tree compare); shared
      `pipeline.compile` / `graph.validate` with IR for invalid fixtures
- [x] **Explicit Textile compatibility** — `--textile` accepts only a
      `.textile` tree, adapts the contracted body subset through existing
      IR/RAG/render paths, compares sequential/parallel HTML, and rejects mixed
      or malformed input with `ETEXTILE`; contract
      [`textile-compatibility.md`](contracts/textile-compatibility.md)
- [x] **Oliver rendering seam tests** — Markdown → HTML through the pinned
      Oliver library (`zig build test-render`; part of `zig build test`):
      - byte-exact heading-id output, footnote/definition-list/table shapes,
        and dual-render determinism pinned in `src/render.zig`
      - contract: [`docs/contracts/oliver-renderer.md`](contracts/oliver-renderer.md)
      - **Note:** Oliver is a pure-Zig dependency pinned by content hash in
        `build.zig.zon` (no C engine, no CMake, no sanitizer surface)
- [x] **HTML assemble / Whiteboard tests** — arena / whiteboard lifetime contracts
      on the HTML path (default CLI + `--html` / `--html-dir` / `--target`):
      - per-page `reset(.free_all)` after flush + publish (`src/compile.zig`)
      - Hold-until-flush proves invalidate-before-flush fails
        (`src/assemble.zig`)
      - render/write failure paths: no bad final publish; temp cleaned
      - PageDb metadata survives each Whiteboard reset
      - fixture goldens: `test/fixtures/html/`
      - contract: [`docs/contracts/html-output.md`](contracts/html-output.md)
      - **Feature 2:** bare `boris` defaults to HTML under `dist/`; IR via `--out`
- [x] **P2 graph-native foundations** — dependency indexes, includes,
      content-addressed fingerprints, opt-in `--incremental` HTML
      (`src/dependency.zig`, `src/cache.zig`, `src/compile.zig`; `zig build test`)
- [x] **P3.1 parallel rendering** — opt-in `--jobs N` bounded workers;
      contract [`parallel-rendering.md`](contracts/parallel-rendering.md)
- [x] **P3.2 watch mode** — opt-in `--watch`; debounced/coalesced/serialized;
      portable polling fallback (platform-qualified);
      contract [`watch-mode.md`](contracts/watch-mode.md)
- [x] **P3.3 multi-target isolation** — `--target`, `--html-layout`,
      `--target-layout`; path-boundary validation; cache namespaces; stage
      commit; selective watch fan-out;
      contract [`multi-target-isolated-output.md`](contracts/multi-target-isolated-output.md)
- [x] **CI coverage** — continuous integration exercises release-critical
      steps (`zig build` + `zig build test` + `test-render` on Linux + macOS)

## Current phase notes

**Default CLI is HTML** under `dist/` (Feature 2). IR remains available via
`--out` / `--no-rag`. **P2 and P3 scale-out on the HTML path are complete.**
**Features 1–7** (native rendering, HTML default, jobs/watch/target, nav/toc,
includes + wiki) and **F8.1–F8.3** graph-native dependencies are Done — see
[`docs/STATUS.md`](STATUS.md). Product **v0.8.1 candidate** / base IR
**0.2.0**. Semantic relations retain their conditional IR **0.3.0** artifacts;
relation-free output remains IR 0.2. Incremental HTML uses the shared direct-edge
resolver and reverse affected-set semantics.

The renderer is Oliver, a pure-Zig dependency pinned by content hash in
`build.zig.zon` — no compile-time host tool is required beyond Zig itself.

Platform-qualified (do not overclaim):

- IR/RAG/HTML publication: staging + rename/copy; **not** whole-tree atomic
  replace on every volume
- Cross-OS bit-identical trees beyond dual-run tests on each CI host
- Watch backends: portable polling is the portable path; host-native FS events
  are not universally claimed


## Historical milestones (pointer only)

m7–m10 / Feature 1–2 campaign detail lives in `CHANGELOG.md` and optional
Historical campaign notes formerly under `archive/` were removed from the tree;
living contracts + STATUS are authoritative.

**Still deferred:** mmap, child-process markdown (forbidden), embedded HTTP
dev server.

## Failure policy

Any checked item that fails verification → **do not ship** that claim. Prefer
fixing code or deliberately amending contracts in the same change set over
documenting “works” without evidence.


