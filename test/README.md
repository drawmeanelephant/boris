# Integration & fuzz harness

Regression harness for Boris’s highest-risk boundaries: Whiteboard reset,
Zig/C ABI, path discovery, graph validation, and deterministic artifacts.

## Commands

```bash
# Full default suite (unit + fixture + hardening + fuzz)
zig build test

# Black-box compiler/CLI contract smoke (build first if needed)
test/cli-contract.sh

# Hardening integration subset
zig build test-harness

# Oliver rendering seam tests (renderer contract fixtures)
zig build test-render
```

All steps are **single-threaded**. No test relies on filesystem enumeration
order (paths and entity ids are sorted before assertions).

The CLI contract smoke exercises the process boundary rather than only Zig
parser units: explicit command routing, report goldens, repeated-output
determinism, and distinct content/usage/I/O exit classes.

## Disposable output

Harness integration tests write only under:

```text
test-output/<label>-<hex>/
```

Each `WorkDir` deletes its tree on cleanup. The `test-output/` root is
gitignored. Safe to remove manually:

```bash
rm -rf test-output
```

Do **not** point harness tests at production `.boris/`, `dist/`, or `rag/`.

## Fixture suite (`test/fixtures/`)

| Path | Purpose |
|------|---------|
| `valid-site/content/` | Multi-page Trunk/Satellite site |
| `empty-page/content/` | Empty markdown page |
| `utf8-bom/content/` | UTF-8 BOM rejection (parser path) |
| `component-fail/content/` | Unregistered component |
| `layouts/ok.html` | Single `{{content}}` |
| `layouts/missing-marker.html` | Missing marker |
| `layouts/duplicate-marker.html` | Duplicate marker |

Contract fixtures under `docs/contracts/fixtures/` remain the normative IR
acceptance set (duplicate id, missing parent, self-parent, cycles,
satellite-of-satellite, malformed frontmatter, …). The harness reuses them
for invalid-graph cases.

## What the harness covers

| Area | Module / step |
|------|----------------|
| Aside tokenizer + HTML + RAG `:::kind` | `src/aside.zig`, `src/hardening_test.zig` |
| IR/RAG dual-run determinism | `src/hardening_test.zig`, pipeline/rag tests |
| Matching IR/RAG graph diagnostic codes | `src/hardening_test.zig` |
| Scanner order independence | `src/hardening_test.zig`, `src/scanner.zig` |
| Duplicate id non-masking | `src/hardening_test.zig`, `src/graph.zig` |
| Output path escape rejection | `src/hardening_test.zig`, `src/identity.zig` |
| Experimental HTML Aside stream | `src/compile.zig`, hardening |
| Frontmatter / component / renderer / graph fuzz | `src/fuzz.zig` |
| Oliver rendering seam contract | `zig build test-render` |

## Fuzz seeds and bounds

Defined in `src/fuzz.zig` (deterministic CI):

| Constant | Default |
|----------|---------|
| `default_seed` | `0xB0B15_F027` |
| `frontmatter_iters` | 256 |
| `component_iters` | 256 |
| `render_iters` | 128 |
| `graph_iters` | 200 |
| `max_input_bytes` | 512 |
| `max_graph_nodes` | 12 |

To re-run with a different seed, call the public `run*Fuzz(seed, iters)`
helpers from a small driver or temporarily change `default_seed` and run
`zig build test`.

## Renderer fuzz

The renderer fuzz harness (`runRenderFuzz`) feeds deterministic bounded random
bytes through the Oliver seam (`src/render.zig`); the renderer must never crash
on arbitrary input. See `src/fuzz.zig`.
