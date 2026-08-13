---
title: "`src/incremental_scale_smoke_test.zig` overview"
id: docs/boris/src/incremental_scale_smoke_test
status: draft
tags: [boris, zig, source-reference, incremental_scale_smoke_test]
---

# `src/incremental_scale_smoke_test.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/incremental_scale_smoke_test/surface-and-execution|Surface and execution]]
* [[docs/boris/src/incremental_scale_smoke_test/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/incremental_scale_smoke_test/review-state|Review state]]

## Executive summary

`src/incremental_scale_smoke_test.zig` is an opt-in integration smoke test for Boris's incremental HTML site compilation pipeline. It is **not** part of the default `zig build test` suite; it is compiled and run exclusively via `zig build test-scale-smoke`. Its module root is `src/incremental_scale_smoke_test.zig`; it imports only `src/compile.zig` (via the `compile` module) and the Zig standard library. It renders through the Oliver-backed seam (`render_mod`) via `compile.zig`.

The file exists to provide bounded, end-to-end confidence that the incremental compilation machinery (`options.incremental = true`) behaves correctly at a scale that cannot be adequately covered by unit tests: 200 pages organized into 20 Trunks, each with 9 Satellites. The three properties it specifically verifies are (1) a cold build writes every page, (2) an unchanged build writes none, and (3) editing a single Satellite causes exactly the edited Trunk cohort (`1 + satellites_per_trunk = 10`) to be re-rendered while all other pages remain cached and unmodified on disk.

A fourth, orthogonal property is verified in the same test body: four-worker parallel compilation of the identical content tree produces a published HTML output tree that is byte-for-byte identical to the sequential output tree. This is a determinism check, not a performance benchmark. No elapsed-time threshold is asserted and the test makes no claims about process-level RSS.

The test is executed in a disposable per-run work directory (`test-output/incremental-scale-smoke-{4-byte-hex-suffix}`) created beneath the repository root and deleted on cleanup. Two parallel subdirectories (`sequential/` and `parallel/`) are used, each with their own `content/`, `dist/`, and `layouts/` trees, so the two runs never share mutable on-disk state.

The confidence provided is: the incremental content-addressed fingerprinting, reverse-dependency expansion, and parallel rendering paths of `compileHtmlSite` agree on the full HTML output for a representative Trunk/Satellite forest. The test does **not** prove the narrowest-possible dirty set, does not cover arbitrary graph shapes, does not assert sub-second latency, does not replace unit-level tests of individual subsystems, and does not cover hostile or adversarial inputs.

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Integration smoke test (opt-in) |
| Conceptual domain | Incremental HTML compilation; parallel determinism |
| Build or test root | `src/incremental_scale_smoke_test.zig` (standalone module) |
| Production runtime dependency | None — test-only, never linked into product binary |
| Expected execution command | `zig build test-scale-smoke` |
| Main collaborators | `src/compile.zig` (`compileHtmlSite`, `CompileStats`) |
| Documentation depth warranted | Medium — one large test, straightforward fixture construction |

## Role in the Boris architecture

This file sits entirely outside the product runtime. It is compiled into a dedicated test binary by the `scale_smoke_mod` / `scale_smoke_tests` build graph nodes in `build.zig`. The `test-scale-smoke` step depends on `render_mod` (the Oliver-backed rendering seam), so the pinned Oliver library is compiled before the test binary links. It is never linked into the product `boris` CLI executable.

Relative to the other test targets:

- **`src/compile.zig` tests** (run by `zig build test`) cover layout errors, Whiteboard lifecycle, render-failure isolation, and write-failure atomicity at unit scale (1–3 pages). They are always executed.
- **`src/incremental_scale_smoke_test.zig`** (this file) covers the same `compileHtmlSite` entry point at a 200-page scale with multiple sequential `compileHtmlSite` invocations against the same `dist/` directory. It is opt-in.
- **`src/render.zig`** owns the Oliver-backed rendering seam; this file reaches it transitively through `compile.zig` / `html_body.zig`.
- **`src/hardening_test.zig`** and **`src/layout_select_hostile_test.zig`** cover adversarial layout and path inputs; unrelated to this file.

The scale smoke test renders through the Oliver-backed seam via `compileHtmlSite` — the same code path the product binary uses for `--html` builds.
