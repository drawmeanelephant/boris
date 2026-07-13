# Release gate — Boris (milestone 9)

Mechanical checklist before tagging a release or claiming a milestone complete.

Run locally:

```bash
zig build
zig build test
zig build test-apex-hostile
zig build test-apex-sanitize   # optional; documents skip if sanitizers unavailable
zig build run -- --input fixtures/content/valid --out /tmp/boris-ir
zig build run -- --input fixtures/content/valid --rag-dir /tmp/boris-rag
```

CI (`.github/workflows/ci.yml`) pins **Zig 0.16.0** and runs `zig build` plus
`zig build test` on `ubuntu-latest`. Prefer also running `test-apex-hostile` in
CI when practical; sanitizer remains optional and must not be claimed if it only
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
- [x] **Whiteboard flush / reset test** — arena / whiteboard lifetime contracts
      verified on the **experimental** HTML assemble path:
      - per-page `reset(.free_all)` after flush + publish (`src/compile.zig`)
      - Hold-until-flush proves invalidate-before-flush fails
        (`src/assemble.zig`)
      - render/write failure paths: no bad final publish; temp cleaned
      - PageDb metadata survives each Whiteboard reset
      - fixture goldens: `test/fixtures/html/`
      - contract: [`docs/contracts/html-output.md`](contracts/html-output.md)
      - **still not** default product CLI surface (`dist/` opt-in / test-only)
- [x] **CI coverage** — continuous integration exercises the release-critical
      steps for the current milestone (`zig build` + `zig build test`)

## Milestone 10 scope (current)

Constrained `<Aside>` tokenizer, `ECOMPONENT`, RAG `:::kind` export,
experimental HTML Aside stream, hardening tests, CI Linux+macOS, self-audit
`docs/AUDIT-v0.1.md`. Sanitizer remains opt-in (`zig build test-apex-sanitize`).

## Milestone 9 scope (prior)

Experimental single-threaded HTML path — Apex, Whiteboard, PageDb, layout
splice, Atomic publish. **Default IR/RAG CLI still do not emit HTML.**

Deferred further: HTML as default CLI product mode, watch mode, concurrency,
mmap, child-process markdown (forbidden).

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
