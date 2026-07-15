# Acceptance (v0.1)

**Status:** planning / checklist — **not** a second normative contract.  
Behavior rules live in the [canonical contracts](README.md). Living phase
snapshot: [`docs/STATUS.md`](../STATUS.md). Release mechanics:
[`docs/RELEASE-GATE.md`](../RELEASE-GATE.md) and `./scripts/release-gate.sh`.

---

## Milestone 2 (historical — complete)

Early contracts-and-fixtures bar (kept for archaeology):

1. Normative contracts exist and use a single parent key name (`parent`).
2. Fixture inventory covers critical graph and parser error categories.
3. `src/fixtures_test.zig` passes (manifest + file presence).
4. `zig build test` passes.
5. README distinguishes implemented vs planned behavior.

---

## v0.1 product acceptance (current — m10)

Claim **v0.1 content-compiler acceptance** only when all of the following hold:

| # | Criterion | Evidence |
|---|-----------|----------|
| 1 | Deterministic scan → bounded frontmatter → PageDb → graph validate/freeze → JSON IR under `--out` (default `.boris/`) | `zig build test`; IR dual-run; contract fixtures under `docs/contracts/fixtures/` |
| 2 | Optional RAG export reuses the same validate path; deterministic corpus including `:::kind` Aside export form | `zig build test` (RAG); `--rag` / `--rag-dir` CLI |
| 3 | Closed diagnostics set for content failures; process exits **0 / 1 / 2 / 3** as documented | [diagnostics.md](diagnostics.md); CLI tests |
| 4 | Constrained `<Aside>` tokenizer on shared IR/RAG compile path (`ECOMPONENT`) | [components.md](components.md); `src/aside.zig` |
| 5 | Apex linked in-process (C ABI); hostile ABI tests green; sanitizer opt-in | [apex-abi.md](apex-abi.md); `test-apex-hostile` |
| 6 | Opt-in HTML path tested (Whiteboard + Aside stream); **not** required as bare-`boris` default | [html-output.md](html-output.md) |
| 7 | CI on Linux + macOS; release-gate script runnable | `.github/workflows/ci.yml`; `scripts/release-gate.sh` |
| 8 | Contracts + STATUS + CHANGELOG describe reality (no “pipeline not implemented” drift) | this tree |

**Explicitly not required for v0.1 content-compiler acceptance**

- HTML `dist/` as the **default** product CLI mode (bare `boris` remains IR)
- Markdown-native `:::` **authoring** (export representation only)
- Full YAML, MDX, nested asides, multi-component registry
- CommonMark-complete Apex (vendor engine is still a minimal stub)

**Landed after m10 (HTML path; not part of the content-compiler acceptance bar)**

These are **implemented & tested** opt-in capabilities — do not document them as
deferred. They are also **not** required to claim the v0.1 IR/RAG acceptance row
above:

- P2: dependency indexes, includes, fingerprints, `--incremental`
- P3.1: bounded `--jobs` parallel HTML render
- P3.2: `--watch` (debounced/coalesced; portable polling fallback)
- P3.3: multi-target `--target` / layouts / isolated cache + stage commit

See [`docs/STATUS.md`](../STATUS.md) and the contracts below.

---

## Normative behavior (canonical only)

Cite these — not redirects or this checklist — for acceptance rules:

| Topic | Canonical document |
|-------|--------------------|
| Frontmatter grammar | [frontmatter.md](frontmatter.md) |
| Source paths and entity IDs | [identity-and-paths.md](identity-and-paths.md) |
| Discovery / scanning | [scanner.md](scanner.md) |
| Parent / graph + JSON IR | [ir-schema.md](ir-schema.md) |
| Diagnostics | [diagnostics.md](diagnostics.md) |
| RAG export | [rag-export.md](rag-export.md) |
| Aside / components | [components.md](components.md) |
| Apex C ABI | [apex-abi.md](apex-abi.md) |
| Opt-in HTML | [html-output.md](html-output.md) |
| Parallel HTML workers | [parallel-rendering.md](parallel-rendering.md) |
| Watch mode | [watch-mode.md](watch-mode.md) |
| Multi-target outputs | [multi-target-isolated-output.md](multi-target-isolated-output.md) |

Index and redirects: [README.md](README.md).

Root fixture inventory (categories / paths):
[`../../fixtures/manifest.json`](../../fixtures/manifest.json).  
Contract IR goldens: [`fixtures/`](fixtures/).
