# Layout-selection hostile fixture

Focused adversarial coverage for PR #50 page layout selection
(`--layout-rule`, `src/layout_select.zig`, contracts §4).

Normative contracts:

- `docs/contracts/templating-and-themes.md` §4
- `docs/designs/page-layout-selection-rfc.md`
- `docs/contracts/multi-target-isolated-output.md`

Happy-path acceptance remains under the parent
`docs/contracts/fixtures/layout-rules/` tree. This directory adds **hostile**
inputs and a Zig harness that must not require Node, Python, or extra
dependencies.

## Layout

```text
hostile/
  README.md                 this file
  REPORT.md                 audit findings (pass / defect classification)
  content/                  minimal Trunk/Satellite graph
  themes/alpha/             managed theme A (multi-layout)
  themes/beta/              managed theme B (mixed-root probe)
  adversarial/              static failure seeds
```

## Harness

```bash
zig build test-layout-hostile   # focused step
zig build test                  # includes this suite
```

Source: `src/layout_select_hostile_test.zig` (Zig-only; links Apex like other
HTML integration tests). Product modules under test are **not** patched by this
suite — failures are reported, not silently “fixed.”

## Scenarios

| ID | Scenario |
|----|----------|
| H1 | Exact id > most-specific glob > role > fallback |
| H2 | Equal-specificity glob ambiguity (fail closed) |
| H3 | Rule-order permutation determinism |
| H4 | Fallback chain: target-layout → html-layout/theme → product default |
| H5 | Invalid paths, traversal, missing files, mixed theme roots |
| H6 | Multi-target isolation (rules + outputs + caches) |
| H7 | Incremental rebuild after selected layout change |
| H8 | Stale output cleanup after layout-rule / content changes |
| H9 | Full-build vs incremental-build byte-for-byte equivalence |
| H10 | Repeated-run determinism |

See `REPORT.md` for classifications and reproduction notes.
