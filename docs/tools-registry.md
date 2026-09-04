# Tools registry

One table mapping every `tools/` member to its build wiring, product coupling,
CI lane, and audience. It complements
[`SOURCE-MAP.md`](SOURCE-MAP.md) (which maps `src/`): a reader should not have
to open each `build.zig` to learn which tools are product surfaces and which
are standalone.

## Coupling classes

| Class | Meaning |
|-------|---------|
| **product CLI** | Built by the root `build.zig`; ships from the repository root |
| **in-process product-module import** | Imports product `src/*.zig` modules directly into its own build graph (shares code with the product, not with the `boris` binary) |
| **product-binary black-box** | Never imports product code; spawns a built `boris` executable as a child process |
| **fully standalone** | No product-module import and no `boris` binary dependency |

## Registry

| Tool | Binary | Build wiring | Coupling class | CI lane | Audience | Why it exists |
|------|--------|--------------|----------------|---------|----------|---------------|
| [`content-audit/`](../tools/content-audit/) | `boris-content-audit` | own `build.zig` (root exposes `zig build test-content-audit` shelling into it) | fully standalone | `content-audit-test` (macOS + Linux, unconditional — never path-gated; one-shot gate `scripts/gate-content-audit.sh`) | content maintainers | Deterministic, read-only audits of source content trees (poetry coverage today); reports never alter graph semantics |
| [`docs-maintenance/`](../tools/docs-maintenance/) | `boris-docs-maintenance` | own `build.zig` | fully standalone | `standalone-tools-test` (macOS + Linux; gate `scripts/gate-standalone-tools.sh`), path-gated on `tools/docs-maintenance/**` | documentation maintainers | Inventories documentation evidence, validates source dossier markers, publishes deterministic status reports |
| [`github-pages-audit/`](../tools/github-pages-audit/) | `boris-github-pages-audit` | own `build.zig` | in-process product-module import (`src/github_pages.zig`, `src/artifact_inventory.zig`) | `build-and-test` (both OS) runs its fixture tests on every push — the redirect-policy regression is guarded on the ordinary baseline, not only when the observer changes | release/observability | Deployment observer for the GitHub Pages publication flow; verifies redirect policy without a live deploy |
| [`scale-smoke/`](../tools/scale-smoke/) | `boris-scale-smoke` | own `build.zig` | product-binary black-box (`--boris PATH`, default `./zig-out/bin/boris`) | none — intentionally not part of the root build or CI gate; opt-in local harness | performance work | Synthetic N-page site generator + timed `boris` builds (`--pages 100`…`10000`) for local scale checks |
| [`search-index/`](../tools/search-index/) | `boris-search-index` | own `build.zig` | in-process product-module import (`src/search_index.zig`) | `standalone-tools-test` (macOS + Linux; gate `scripts/gate-standalone-tools.sh`), path-gated on `tools/search-index/**` and `src/search_index.zig` | site operators | Consumes final rendered HTML (never Markdown/IR) and emits the deterministic `search-index.json` |
| [`source-rag/`](../tools/source-rag/) | `boris-source-rag` | root `build.zig` (`zig build source-rag`) | fully standalone | `build-and-test` (both OS) — its unit + mini-export tests are wired into the root `zig build test` aggregate | agents / LLM notebooks | Packs project source into a deterministic markdown corpus for upload (profiles, bundles, `--token-budget`) |
| [`testdata-generator/`](../tools/testdata-generator/) | `boris-testdata` | both: own `build.zig` CLI, and root `build.zig` imports `src/generator.zig` as a module for product fixture tests | product-binary black-box in `run` mode (`--boris PATH` spawns the built binary); the generator module itself is imported in-process by root fixture tests | `testdata-generator-test` (Linux), path-gated on `tools/testdata-generator/**` | test authors | Deterministic fixture generation (sites, manifests, barbs) and bounded companion runs against a built `boris` |

## Reading the wiring

- **Own `build.zig`** tools are invoked as `zig build --build-file tools/<name>/build.zig [test]`. `source-rag` is the exception: it is declared in the root `build.zig` and run via `zig build source-rag`.
- The root `build.zig` reaches into `tools/` in exactly two places: the `source-rag` executable/test declaration, and `testdata-generator/src/generator.zig` as the shared `fixture_generator` module for publication fixture tests. Everything else under `tools/` is invisible to the root build graph except through explicit `zig build --build-file` steps (`test-content-audit`, `test-github-pages-audit`).
- **Split-vs-keep**: the registry makes the seam visible. `search-index` and `github-pages-audit` are the only tools that import product modules — moving them out of tree would take their `src/*.zig` counterparts with them (both already keep that surface narrow). `content-audit`, `docs-maintenance`, and `source-rag` have no product coupling and could graduate without touching the product. `scale-smoke` and `testdata-generator` depend only on a built `boris` binary, so they move freely as long as the CLI contract holds.

## Keeping this file true

Every column is derived from the tree: build wiring from the `build.zig`
presence/imports, coupling from `@import`/`b.path("../../src/…")` and child
process spawns, CI lanes from `.github/workflows/ci.yml` and
`scripts/gate-*.sh`. When adding a `tools/<name>/` directory, add its row in
the same change.
