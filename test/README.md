# Integration & fuzz harness

Regression harness for Boris’s highest-risk boundaries: Whiteboard reset,
Zig/C ABI, path discovery, graph validation, and deterministic artifacts.

## Commands

```bash
# Full default suite (unit + fixture + hardening + fuzz)
zig build test

# Hardening integration subset
zig build test-harness

# Optional: Apex C ASan+UBSan smoke (opt-in; documented skip if unavailable)
# Not required on CI (sanitizer runtime varies by host).
zig build test-apex-sanitize

# Optional: hostile Apex C test double (swaps apex.c → apex_hostile.c)
zig build test-apex-hostile
```

All steps are **single-threaded**. No test relies on filesystem enumeration
order (paths and entity ids are sorted before assertions).

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
| Frontmatter / component / Apex / graph fuzz | `src/fuzz.zig` |
| Hostile Apex ABI double | `zig build test-apex-hostile` |

## Fuzz seeds and bounds

Defined in `src/fuzz.zig` (deterministic CI):

| Constant | Default |
|----------|---------|
| `default_seed` | `0xB0B15_F027` |
| `frontmatter_iters` | 256 |
| `component_iters` | 256 |
| `apex_iters` | 128 |
| `graph_iters` | 200 |
| `max_input_bytes` | 512 |
| `max_graph_nodes` | 12 |

To re-run with a different seed, call the public `run*Fuzz(seed, iters)`
helpers from a small driver or temporarily change `default_seed` and run
`zig build test`.

## Apex hostile double

`vendor/apex/apex_hostile.c` implements the Apex C ABI with intentional dirty
error outputs. Control tags at the start of the markdown input:

| Tag | Behavior |
|-----|----------|
| `@HOSTILE_OOM` | `APEX_ERR_OOM` + poison pointer/len |
| `@HOSTILE_ARGS` | `APEX_ERR_ARGS` + poison |
| `@HOSTILE_NULL_LEN` | `APEX_OK` but null pointer + nonzero len |
| `@HOSTILE_UNKNOWN_ERR` | status `99` + poison |
| *(other)* | success with tiny arena HTML |

Linked **only** into `test-apex-hostile`; product binaries always use real
`vendor/apex/apex.c`.
