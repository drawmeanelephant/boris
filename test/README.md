# Integration & fuzz harness

Regression harness for Boris’s highest-risk boundaries: Whiteboard reset,
Zig/C ABI, path discovery, graph validation, and deterministic artifacts.

## Commands

```bash
# Full default suite (unit + fixture + integration + fuzz)
zig build test

# Same tests, named step (alias for documentation / CI scripts)
zig build test-harness

# Fuzz / property suite only (still via the main test binary filters if needed)
# Prefer the full suite; fuzz lives in src/fuzz.zig and is part of `zig build test`.
zig build test

# Optional: Apex C ASan+UBSan smoke (real engine, C-only binary)
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
| Valid multi-page IR | `src/harness.zig` |
| Invalid graph cases | harness + contract fixtures |
| Frontmatter + UTF-8 | harness |
| Component tokenize / render | harness |
| Empty + large-but-bounded page | harness |
| Layout markers | harness + `test/fixtures/layouts/` |
| RAG-only vs IR build | harness |
| Repro HTML / graph / RAG (two runs) | harness |
| Whiteboard per-page reset isolation | harness |
| Frontmatter fuzz | `src/fuzz.zig` |
| Component fuzz | `src/fuzz.zig` |
| Apex fuzz (pointer/len contracts) | `src/fuzz.zig` |
| Random graph vs reference checker | `src/fuzz.zig` |
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
