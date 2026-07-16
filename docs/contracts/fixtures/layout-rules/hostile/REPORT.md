# Layout selection hostile audit report (PR #50)

**Date:** 2026-07-15  
**Branch:** `grok/layout-selection-hostile` (from `origin/main` @ `711538b`)  
**Scope:** Audit merged page layout selection only. **No product source patches.**  
**Harness:** `src/layout_select_hostile_test.zig` · fixtures under this directory  
**Gates run:** `zig build test-layout-hostile`, `zig build test`, `./scripts/release-gate.sh`

## Method

1. Checked out fresh `origin/main` (includes merge of PR #50).
2. Added Zig-only hostile fixtures + integration harness (no Node/Python deps).
3. Probed pure selector logic (`layout_select`), CLI parse (`cli.parseOptions`),
   target validation (`rejectMixedThemeRoots` / `effectiveLayout`), and HTML
   compile (`compileHtmlSite` / `compileHtmlSiteMulti`).
4. Compared outcomes against `docs/contracts/templating-and-themes.md` §4 and
   the release-gate layout-rules block (4c2).

Evidence order: executable harness behavior → contracts → STATUS/CHANGELOG.

## Gate results

| Gate | Result |
|------|--------|
| `zig build test-layout-hostile` | **PASS** (all hostile cases) |
| `zig build test` | **PASS** |
| `./scripts/release-gate.sh` | **PASS** (including 4c2 layout-rules block) |

## Scenario matrix

Classification keys (AGENTS review discipline):

- **Confirmed defect** — reproduced failure / unsafe path / contract contradiction
- **Likely defect** — strong code-path evidence without reliable repro
- **Insufficient evidence** — claim not established by available tests/env
- **Documented limitation** — matches an explicit current limitation
- **Non-issue / packet drift** — contradicted by current evidence

| ID | Scenario | Result | Classification |
|----|----------|--------|----------------|
| H1 | Exact id > most-specific glob > role > fallback | Pass (pure + HTML `data-layout` markers) | Non-issue |
| H2 | Equal-specificity glob ambiguity | Pass (`AmbiguousGlob`; no published HTML) | Non-issue |
| H3 | Rule-order permutation determinism | Pass (selection + digest + byte-identical HTML trees) | Non-issue |
| H4 | Fallback: target-layout → theme/html-layout → product default | Pass (CLI effectiveLayout + HTML default build) | Non-issue |
| H5a | Mixed theme roots | Pass (`MixedThemeRoots`; no publish) | Non-issue |
| H5b | Missing layout file | Pass (fail closed; no silent next-rule fallback) | Non-issue |
| H5c | Traversal / `..` layout paths | Pass as fail-closed or non-escaping publish; see notes | Documented limitation (see below) |
| H5d | Invalid selectors / duplicates / IR conflict | Pass (usage errors at parse) | Non-issue |
| H6 | Multi-target isolation | Pass (distinct markers + isolated cache namespaces) | Non-issue |
| H7 | Incremental rebuild after selected layout change | Pass (home→alt rewrite; noop when unchanged) | Non-issue |
| H8 | Stale cleanup after content remove + layout-rule change | Pass (orphan HTML scrub on full rebuild; marker update) | Non-issue |
| H9 | Full vs incremental byte-for-byte | Pass (published HTML+assets) | Non-issue |
| H10 | Repeated-run determinism | Pass (3 full trees + stable no-op manifest) | Non-issue |

### Release-gate cross-check (4c2)

Already covered on `main` and re-confirmed green:

- exact/glob/role/fallback markers
- rule-order permutation byte-identical
- incremental cache `boris-cache-v2-layout-rules` + `selected_layout`
- ambiguous globs → exit 2, no HTML
- `layout:` frontmatter → exit 1 `EFRONTMATTER`
- `--layout-rule` + `--out` → exit 2
- mixed theme roots → exit 2

## Findings

### Confirmed defects

**None** in the hostile matrix above. Layout selection on merged PR #50 matches
the contract for precedence, ambiguity, order independence, multi-target
isolation, incremental dirtying on selected-layout change, full/inc equivalence,
and repeated-run determinism under the harness.

### Documented limitations / observations (not ship blockers)

1. **Layout path grammar is load-time, not selector-parse-time for `..`.**  
   Selectors (`id:` / `glob:` / `role:`) reject path-like nonsense in the
   *selector* value, but **layout path** arguments are ordinary file paths.
   Hostile paths containing `..` may:
   - be rejected as `MixedThemeRoots` when they break the single managed root
     rule (e.g. `…/alpha/layouts/../../themes/beta/layouts/main.html` yields a
     non-managed root vs managed fallback), or
   - fail at open/load, or
   - open successfully if they resolve to a real file still under the workspace.  
   Theme *asset* paths still reject `..` via the closed asset grammar. This is
   consistent with “trusted build-owner layout paths” rather than a silent
   publish of foreign theme roots; operators should still treat layout argv as
   trusted configuration.

2. **Cache manifests are incremental-only.**  
   `.boris-cache/manifest.json` (with `selected_layout`) is written when
   `--incremental` (or watch) is set. Full builds do not leave a layout-rules
   cache namespace. Contract and release-gate already exercise the incremental
   path; hostile H6/H10 cover it explicitly.

3. **Stale HTML scrub on page removal is strongest on full rebuild.**  
   When a page leaves the content set, full rebuild walks `dist/**/*.html` and
   deletes orphans; incremental prefers prior-manifest entries. H8 uses a full
   rebuild for the delete case and incremental for layout-rule rewrite — both
   match current compile behavior.

### Speculative hardening (not defects)

- Stronger lexical rejection of `..` / absolute layout paths at CLI attach time
  would make H5c uniformly usage-exit-2 without relying on load/mixed-root.
- Publishing `selected_layout` diagnostics on non-quiet builds could aid
  operator debugging (not required by current contract).

## How to reproduce the harness

```bash
# From repo root (Zig 0.16+)
zig build test-layout-hostile
# or full suite
zig build test
# product acceptance for layout-rules
./scripts/release-gate.sh
```

Static content/theme fixtures:

```text
docs/contracts/fixtures/layout-rules/hostile/content/
docs/contracts/fixtures/layout-rules/hostile/themes/alpha/
docs/contracts/fixtures/layout-rules/hostile/themes/beta/
```

## Remediation cards

None required for ship of PR #50 layout selection based on this audit.

Optional follow-ups (out of scope for this task):

| Card | Severity | Verification |
|------|----------|--------------|
| Lexically reject `..` / absolute layout paths on `--layout-rule` / `--target-layout` / `--html-layout` | Low (hardening) | extend hostile H5c + CLI parse tests |

## Summary

Merged PR #50 layout selection is **behaviorally consistent** with its contract
under hostile integration pressure. The harness and report are additive only;
product modules were not modified.
