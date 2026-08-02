# Boris test-throughput audit

Status: repository audit, 2026-08-02

Audited integration revision: `afterparty` at `21fad24` (PR #294 merged)

Product state described by the repository: v0.8.1 candidate

Task: measure whether `zig build test` wall time is gated by a build-graph
serialization defect; if no build-system change produces a meaningful
improvement, record a documentation-only audit instead of speculative
refactoring.

## Executive conclusion

The `zig build test` graph is already fully sibling-parallel, so no
build-graph change improves throughput. The warm wall time floor (≈16–20s
at default job count on a 10-core Apple Silicon host) is structural, not a
scheduler defect:

- Every test root is a direct dependent of the aggregate `test` step; the
  42 test-run steps form a flat fan-out with no hidden dependency chains and
  no shared accumulator that would serialize executions.
- `ensure_apex`, the only shared gate in the graph, is a fast no-op when the
  Apex kernel/CMake stamp is current (warm ≈30–400 ms wall), so it does not
  gate or serialize the parallel test fan-out.
- Job-count scaling is present and monotonic: `-j1`→`-j8` yields ≈3× wall
  speedup under contended load. There is no missing-parallelism defect.
- The residual floor comes from ~9× duplication of one shared test suite:
  6,721 total test executions resolve to only 767 unique test names (≈8.8×
  redundancy). Four co-dominant roots (`main` 661, `compile` 556,
  `hardening_test` 585, `layout_select_hostile_test` 605 test blocks) each
  import the same core modules (apex, parser, graph, aside, rag, wikilink,
  …), so each binary re-runs that shared suite as part of its own body. That
  is inherent to Zig's test compilation model: a test binary re-runs the test
  blocks of every transitively-imported module. It is not a bug in
  `build.zig`.
- No single test executable dominates wall time; the largest binary tops out
  at ≈13–17 s solo versus a ≈16–24 s total at `-j8`, i.e. four co-dominant
  binaries, so the "shard a dominant test root" guardrail does not apply. A
  structural fix would require moving shared test blocks out of the shared
  modules, which is explicit test-file reorganization — disallowed here as
  speculative refactoring.
- Verdict: **documented limitation, no product or build change**. CI already
  runs `zig build test` at the runner's default job count on its own core
  budget and inherits the same structural floor; there is no build-graph
  defect to repair within scope.

## Scope and evidence method

The audit followed the repository evidence order:

1. current executable behavior and `build.zig`;
2. canonical contracts (`docs/contracts/acceptance.md`,
   `docs/contracts/parallel-rendering.md`);
3. `AGENTS.md`;
4. `docs/STATUS.md`, `CHANGELOG.md`;
5. `scripts/release-gate.sh`, `scripts/verify-publication-conformance.sh`;
6. commentary and historical notes.

Primary implementation paths inspected:

- `build.zig` — the `test` step and its 42 fan-out dependencies;
- `docs/contracts/acceptance.md` — P3.1 bounded parallel rendering and the
  test-baseline gate;
- `.github/workflows/ci.yml` — CI runs `zig build`, `zig build test`,
  `zig build test-publication-conformance`, and `zig build test-apex-hostile`
  at runner default job counts.

## Environment and method

- Host: Apple Silicon (arm64), `hw.ncpu` = 10 logical cores (4 performance +
  6 efficiency), 16 GiB RAM, Zig 0.16.0.
- All timings are `zig build test` on an already-warm build cache after at
  least one warm-up run; cold runs are explicitly marked.
- Background load during measurement: load average 5–9 (IDE/indexer;
  incompatible with sub-second precision). Each configuration was repeated at
  least twice; the interleaved **final sweep** is the reference set.

## Measurements

Warm idle, `--summary all`:

| Job count | Round 1 | Round 2 | Round 3 |
|---:|---:|---:|---:|
| `-j1` | 44.19 | 53.78 | 44.08 |
| `-j2` | 41.31 | 39.83 | 40.83 |
| `-j4` | 29.67 | 37.49 | 27.02 |
| `-j8` | 17.33 | 23.70 | 17.48 |
| default (no `-j`, CPU-count) | 17.09 | 16.09 | 20.19 |

Interleaved warm re-run under heavier background load:

| Job count | Run 1 | Run 2 |
|---:|---:|---:|
| `-j1` | 52.87 | 64.73 |
| `-j2` | 61.28 | 58.97 |
| `-j4` | 43.95 | 31.52 |
| `-j8` | 23.70 | 21.87 |
| default | 31.69 | 44.62 |

Cold cache (all CPU-bound observed through `sample`):

- `-j1`: real **123.96 s**, user 160.08 s (load-average-driven)
- default: real **55.64 s**, user 226.73 s; CPU samples: 56 samples, mean
  255.7%, peak 982.5% — the cold path saturates cores; it is not
  single-thread-bound.

Largest test roots (tests / solo wall):

| Root | Tests | Solo wall |
|---|---:|---:|
| `main` | 661 | ≈13.1–17.5 |
| `hardening_test.test` | 585 | ≈12.2 |
| `layout_select_hostile_test.test` | 605 | ≈12.3 |
| `compile.test` | 556 | ≈12.8 |

Apex/BMC-linked heavy steps at `-j4`: `test-publication-touches-fixture`
15.8 s, `test-publication-conformance` 9.4 s; the remaining publication steps
are ≤2.5 s each.

## Duplication analysis

From a full aggregate test log:

- total `test` blocks executed across every binary: **6,721**;
- unique test names: **767**;
- effective redundancy: **≈8.8×**.

Concretely: the four co-dominant roots, provably, each re-execute the
`../src/` module suite. Their architecture is by design — each root is an
integration harness that exercises the real `compile`/`graph`/`apex`
pathways — but the cost is structural: in Zig, a `zig build test` artifact
re-compiles tests for every transitively imported module, so no build.zig
declaration removes that exact duplication. The only high-leverage fix is
moving the shared test halo out of the roots into their own binaries, which
is a content/test-file reorganization (guardrail constraint) and not a
throughput change to the per-root suites remaining.

The scaling result confirms the graph is healthy: warm all-core runs
aggregate ≈63–92 s total CPU (user+sys) into ≈16–24 s wall, i.e. the host's
cores stay busy and the graph has no idle serialization. The marginal wall
improvement from `-j8`→default is <1 s on this host.

## Findings

- **Confirmed defect: none.** No build-graph serialization issue was
  found; all test artifacts are siblings under `test`.
- **Documented limitation (primary):** ~9× re-execution-duplicated shared
  test suite across the four co-dominant roots is innate to Zig's
  test-compilation model; it caps parallel throughput on any single host at
  roughly the largest root's runtime. Not fixable by build.zig change.
- **Documented limitation:** host dimension matters. Under a 5–9 load
  average the warm default run varies from ≈16 s to ≈45 s; that is
  environment noise, not graph behavior. Local dev destinations should use
  the default job count and expect their own variance.
- **Insufficient evidence:** whether a dedicated CI runner core budget
  would show a wall-time defect: GitHub `ubuntu-latest`/`macos-latest` cores
  and the compiler cache are outside the repository's control; the audit
  could only measure the local host and cannot prove a CI-only bottleneck.
- **Non-issue:** repeated runs at a fixed job count differ
  run-to-run (up to 2×) due to contention; the diff is within host noise and
  is not a determinism difference in outputs (the publication suite already
  asserts byte-identical sequential/parallel outputs).

## Recommendation and smallest remediation

- **Keep the current graph.** Add no build.zig parallelization, no
  `-j` default, no new step. `zig build test` at the runner default is
  already maximally parallel on any host.
- **Do not shard any root.** No test executable dominates (guardrail: only
  when measurement proves one does).
- **Optional future card** (out of scope here): move shared module tests once
  into a single shared binary to collapse the ~9× duplication. This is
  explicit test-file reorganization with its own acceptance surface and must
  be requested with a concrete PR.
- **Tooling note for authors:** when iterating locally, run
  `zig build test --summary all` with no `-j` flag; if the dev machine is
  busy, prefer reducing host load over adding `-j` threads (they do not
  help past the root-floor).

This audit makes no product behavior or build change. It records measurements
and the structural reason no meaningful build-graph change exists within the
guardrails.