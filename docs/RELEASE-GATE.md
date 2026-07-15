# Release gate — Boris (v0.1 / post-P3)

Mechanical checklist before tagging a release or claiming a milestone complete.

Run locally:

```bash
zig build
zig build test
zig build test-apex-hostile
zig build test-apex-sanitize   # optional; documents skip if sanitizers unavailable
zig build run -- --input fixtures/content/valid --out /tmp/boris-ir
zig build run -- --input fixtures/content/valid --rag-dir /tmp/boris-rag
zig build run -- --input test/fixtures/html/content --html-dir /tmp/boris-dist
zig build package              # optional; review tar under packages/ (not ship-blocking)
./scripts/release-gate.sh      # preferred one-shot mechanical gate
```

CI (`.github/workflows/ci.yml`) pins **Zig 0.16.0** and runs `zig build`,
`zig build test`, and `zig build test-apex-hostile` on `ubuntu-latest` and
`macos-latest`. Sanitizer remains optional and must not be claimed if it only
skipped.

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
- [x] **Deterministic IR test** — JSON IR emit is byte-stable across dual runs
      on the same host (pipeline dual-export diff of `manifest.json` /
      `graph.json`)
- [x] **RAG determinism test** — dual RAG export to distinct dirs is
      byte-identical (`src/rag.zig` full-tree compare); shared
      `pipeline.compile` / `graph.validate` with IR for invalid fixtures
- [x] **Apex ABI tests** — in-process Apex C ABI integration covered:
      - real `@cImport` unit tests in `src/apex.zig` (part of `zig build test`)
      - hostile C double via `zig build test-apex-hostile`
      - optional ASan+UBSan smoke via `zig build test-apex-sanitize`
        (document skip when unavailable; do not pretend it ran)
      - contract: [`docs/contracts/apex-abi.md`](contracts/apex-abi.md)
      - **Note:** vendor engine remains a **minimal markdown stub** (not
        CommonMark); hostile tests cover the ABI boundary, not full fidelity
- [x] **HTML assemble / Whiteboard tests** — arena / whiteboard lifetime contracts
      on the **opt-in** HTML path (`--html` / `--html-dir` / `--target`):
      - per-page `reset(.free_all)` after flush + publish (`src/compile.zig`)
      - Hold-until-flush proves invalidate-before-flush fails
        (`src/assemble.zig`)
      - render/write failure paths: no bad final publish; temp cleaned
      - PageDb metadata survives each Whiteboard reset
      - fixture goldens: `test/fixtures/html/`
      - contract: [`docs/contracts/html-output.md`](contracts/html-output.md)
      - **still not** the bare-`boris` default product surface (IR remains default)
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
      steps (`zig build` + `zig build test` + `test-apex-hostile` on Linux + macOS)

## Current phase notes

**v0.1 content-compiler surface** remains the bare CLI default (IR under
`.boris/`). **P2 and P3 scale-out on the HTML path are complete.** Next product
work is Apex CommonMark fidelity and promoting HTML to the default CLI — see
[`docs/STATUS.md`](STATUS.md).

Platform-qualified (do not overclaim):

- IR/RAG/HTML publication: staging + rename/copy; **not** whole-tree atomic
  replace on every volume
- Cross-OS bit-identical trees beyond dual-run tests on each CI host
- Watch backends: portable polling is the portable path; host-native FS events
  are not universally claimed
- Sanitizer smoke: host-dependent; skip is not a pass

## Milestone 10 scope (historical)

Constrained `<Aside>` tokenizer, `ECOMPONENT`, RAG `:::kind` export,
HTML Aside stream, hardening tests, CI Linux+macOS, self-audit
`docs/AUDIT-v0.1.md`. Sanitizer remains opt-in (`zig build test-apex-sanitize`).

## Milestone 9 scope (historical)

Experimental single-threaded HTML path — Apex, Whiteboard, PageDb, layout
splice, Atomic publish. Later work wired HTML as **opt-in CLI** and added
P2/P3 capabilities on that path.

**Still deferred as product defaults / fidelity:** HTML as bare-`boris` default
CLI mode, CommonMark-complete Apex, mmap, child-process markdown (forbidden).

## Milestone 8 scope (prior)

Native in-process Apex C engine (`vendor/apex/`), defensive Zig wrapper
(`src/apex.zig`), C compilation/linking in `build.zig`, hostile ABI tests,
optional sanitizer smoke, normative ABI contract.

## Milestone 7 scope (prior)

Optional deterministic product RAG export (`--rag` / `--rag-dir`) reusing
scanner, parser, PageDb, and `graph.validate`; staging publication; catalog
schema; dual-export determinism tests; contract
`docs/contracts/rag-export.md`.

## Failure policy

Any checked item that fails verification → **do not ship** that claim. Prefer
fixing code or deliberately amending contracts in the same change set over
documenting “works” without evidence.

For optional sanitizer: a documented “not available on this host” skip is
acceptable; a green log line without a successful run is not.
