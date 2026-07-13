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
| 6 | Experimental HTML path tested (Whiteboard + Aside stream); **not** required as default CLI | [html-output.md](html-output.md) |
| 7 | CI on Linux + macOS; release-gate script runnable | `.github/workflows/ci.yml`; `scripts/release-gate.sh` |
| 8 | Contracts + STATUS + CHANGELOG describe reality (no “pipeline not implemented” drift) | this tree |

**Explicitly not required for v0.1 acceptance**

- HTML `dist/` as default product CLI mode
- Markdown-native `:::` **authoring** (export representation only)
- Full YAML, MDX, nested asides, multi-component registry
- Incremental rebuild, reverse dependency index, concurrency, watch mode

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
| Experimental HTML | [html-output.md](html-output.md) |

Index and redirects: [README.md](README.md).

Root fixture inventory (categories / paths):
[`../../fixtures/manifest.json`](../../fixtures/manifest.json).  
Contract IR goldens: [`fixtures/`](fixtures/).
