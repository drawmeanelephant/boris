# Release gate — Boris (milestone 1)

Mechanical checklist before tagging a release or claiming a milestone complete.
At **milestone 1**, only the Zig foundation and help CLI are in scope.

Run locally (when available):

```bash
zig build
zig build test
```

CI (`.github/workflows/ci.yml`) pins **Zig 0.16.0** and runs `zig build` plus
`zig build test` on `ubuntu-latest`.

## Checklist

Items stay unchecked until the corresponding work is implemented **and**
verified. Do not check an item because a design doc exists.

- [ ] **Build configuration** — reproducible `build.zig` / `build.zig.zon`,
      executable name `boris`, Zig 0.16.0 pin aligned across package metadata
      and CI
- [ ] **Scanner / parser tests** — discovery and frontmatter grammar covered by
      automated tests against fixtures
- [ ] **Graph tests** — Trunk / Satellite parent validation (missing parent,
      cycles, duplicates, role rules) covered by tests
- [ ] **Deterministic IR test** — JSON IR emit is byte-stable across dual runs
      on the same host (golden or dual-export diff)
- [ ] **RAG determinism test** — dual RAG export to distinct dirs is
      byte-identical (`diff -r`)
- [ ] **Apex ABI tests** — in-process Apex C ABI integration covered (including
      hostile / sanitize smoke where required)
- [ ] **Whiteboard flush / reset test** — arena / whiteboard lifetime contracts
      verified (e.g. capacity / free-all expectations)
- [ ] **CI coverage** — continuous integration exercises the release-critical
      steps for the current milestone (not only green empty targets)

## Milestone 1 scope (for context)

In scope now: package foundation, `boris --help` / `-h`, unit tests for the
usage parser, CI build + test with Zig 0.16.0.

Out of scope until later milestones: content scan, graph IR, Apex, RAG, HTML
`dist/`, watch mode, concurrency, mmap, generic configuration frameworks.

## Failure policy

Any checked item that fails verification → **do not ship** that claim. Prefer
fixing code or deliberately amending contracts in the same change set over
documenting “works” without evidence.
