# Publication conformance evidence: C01, C02, C03, C04, C05, C06, C07, C08

Date: 2026-08-02
Base: `afterparty` at `8c0e0d1` (PR #291)
Evidence branch: `codex/conformance-w1-s1-remediation`
Pull request: draft (W1/S1 remediation)

This branch is the W1/S1 remediation of the round-2 publication-conformance
suite: it repairs the two confirmed defects retained by PR #291 (watcher exit
on failed include rebuild; active-SVG rejection exit class) and re-runs the
full C01–C08 evidence. The C02/C03/C04/C08 evidence and the C01/C05/C06/C07
non-defect cases are unchanged and still pass.

## Authority and scope

This is a repair-and-evidence branch for the two confirmed defects retained by
the round-2 publication-conformance suite. Normative authority was resolved in
this order: the relevant contracts under `docs/contracts/`, current executable
behavior, focused tests, and the retained black-box evidence. Production
changes are limited to the W1 and S1 repair boundaries in `src/watch.zig`,
`src/main.zig`, and `src/compile.zig`; the rest of the branch touches
`scripts/verify-publication-conformance.sh`, the retained fixture trees under
`docs/audits/publication-conformance/`, this report, and a changelog fragment.
The material-observation labels below are limited to: `Confirmed defect`,
`Likely defect`, `Insufficient evidence`, `Documented limitation`, and
`Non-issue / packet drift`. The report does not turn the remaining gaps into
confirmed defects.

## Executable verification

The single entry point is:

```text
zig build test-publication-conformance
```

The build step installs the Boris binary, then runs
`scripts/verify-publication-conformance.sh`. CI runs the same step after the
ordinary test step. The verifier:

- reads retained fixtures and the pipe-separated
  `c02-includes-fragments/depth-cases.psv` declaration;
- generates the depth-32/depth-33 include chains, the C05 incremental
  workspace and C06 cache/watch workspaces (each scenario reuses one dedicated
  output directory: an `--incremental` first publication, then `--incremental`
  rebuilds into that same target), a bounded watch-lifecycle harness that
  terminates via SIGTERM and is reaped in the exit trap, and C07
  SVG/collision trees under the fixed, ignored
  `.zig-cache/publication-conformance/` tree;
- captures stdout and stderr separately and asserts every exit code;
- compares successful HTML, sitemap, RSS, and IR artifacts with checked-in
  goldens or repeat artifacts;
- compares retained diagnostics byte-for-byte with checked-in snapshots;
- verifies failed HTML targets have no final HTML artifacts, and failed IR
  targets have no `graph.json` or `manifest.json` (the intentional
  `build-report.json` remains);
- runs repeat comparisons for successful HTML, sitemap, and RSS cases;
- removes its temporary tree on exit, including failure.

All verifier inputs and CLI paths are repository-relative. The script has no
randomness, timestamps, absolute fixture paths, or environment-derived source
bytes. It fails visibly on the first mismatch.

The failed HTML compiler creates an empty requested output root before content
validation; the verifier therefore checks the meaningful contract boundary:
no final HTML artifact is present. Failed IR publication intentionally retains
only its unsuccessful `build-report.json`; graph-dependent artifacts are
absent. This is observed behavior, not a production change.

## Fixture index

| Area | Retained declaration or fixture | Verifier cases |
|---|---|---|
| C01 Textile HTML | `c01-textile/content/`, `c01-textile/layout.html`, page goldens, 12 case dirs with `expected/stderr.txt` | `c01-valid`, `c01-valid-jobs4`, `c01-valid-incr`, `c01-valid-incr-jobs4`, `c01-*` failure matrix |
| C02 includes/fragments | `c02-includes-fragments/cases/` plus pipe-separated `depth-cases.psv` | `c02-01`–`c02-09`, `c02-depth-32`, `c02-depth-33` |
| C03 sitemap | `c03-sitemap/content/`, sitemap golden, CLI snapshots | `c03-trailing`, `c03-no-trailing`, `c03-invalid-*` |
| C04 RSS | `c04-rss/content/`, feed and CLI snapshots | `c04-feed-2/3/4`, `c04-missing-*`, `c04-invalid-*` |
| C05 layout precedence | `c05-layout-precedence/content/`, marker layouts, managed theme, failure snapshots | `c05-explicit`, `c05-rule-id`, `c05-rule-glob`, `c05-rule-role`, `c05-theme`, `c05-multi`, `c05-missing-layout`, `c05-missing-marker`, `c05-duplicate-marker`, `c05-ambiguous-glob`, `c05-incr-base/win/lose` (one reused target) |
| C06 cache/watch | `c06-cache-watch/content/`, `theme/`, `layout.html`, `dup.html`, failure snapshots | `c06-noop`, `c06-source-edit`, `c06-source-delete`, `c06-include-edit`, `c06-include-missing`, `c06-parse-failed`, `c06-layout-dup`, `c06-theme`, `c06-content-asset`, `c06-sitemap`, `c06-search`, `c06-watch`, `c06-watch-fail` (same-session recovery), `c06-watch-svg` (unsafe-SVG same-session recovery) |
| C07 assets/SVG | `c07-asset-collisions/content/`, `layout.html`, 13 snapshots | `c07-svg-*` (9 constructs), `c07-svg-multi`, `c07-valid`, `c07-valid-jobs4`, `c07-valid-incr`, `c07-theme-page`, `c07-symlink`, `c07-traversal`, `c07-sitemap` |
| C08 parser/Unicode | `c08-parser-unicode/` plus repository invalid-UTF-8 corpus | `c08-valid`, `c08-invalid-*` |

## C02 — includes and heading fragments

### Generated depth declaration

`c02-includes-fragments/depth-cases.psv` retains the requested depth, title,
terminal marker, expected exit, expected HTML golden or stderr snapshot. The
generator uses exactly these byte-stable inputs:

- root: `content/index.md`;
- root frontmatter: `---\ntitle: <title>\n---\n`;
- root include: `{{include includes/level-01.md}}\n`;
- levels: `content/includes/level-%02d.md`;
- each non-terminal include:
  `{{include includes/level-%02d.md}}\n`;
- terminal content: the declared marker followed by one newline.

The retained declarations are `depth-32|32|...` and `depth-33|33|...`.
The old mechanically identical `level-NN.md` forests are not committed.

### Case map

| Retained input or declaration | Verifier case | Expected result and assertion |
|---|---|---|
| `cases/01-include-success` | `c02-01` | Exit 0; exact `expected/index.html`; repeated full HTML tree |
| `cases/02-missing-include` | `c02-02` | Exit 1; exact `expected/stderr.txt`; no final HTML artifact |
| `cases/03-direct-cycle` | `c02-03` | Exit 1; exact cycle diagnostic; no final HTML artifact |
| `cases/04-long-cycle` | `c02-04` | Exit 1; exact cycle diagnostic; no final HTML artifact |
| `cases/05-valid-fragment` | `c02-05` | Exit 0; exact HTML golden; repeated full HTML tree |
| `cases/06-missing-fragment` | `c02-06` | Exit 1; exact `EREFERENCEMISSING`; no final HTML artifact |
| `cases/07-fragment-after-include` | `c02-07` | Exit 0; exact HTML golden; repeated full HTML tree |
| `cases/08-duplicate-heading` | `c02-08` | Exit 0; exact page and `target.html` goldens; repeated full HTML tree |
| `cases/09-nested-include-path` | `c02-09` | Exit 0; exact HTML golden; repeated full HTML tree |
| `depth-cases.psv: depth-32` | `c02-depth-32` | Generated 32-level chain, exit 0; exact `cases/10-depth-32/expected/index.html` |
| `depth-cases.psv: depth-33` | `c02-depth-33` | Generated 33-level chain, exit 1; exact `cases/11-depth-33/expected/stderr.txt`; no final HTML artifact |

The success observations cover include placement, nested relative resolution,
heading lookup after an include, duplicate heading id membership, and the
depth-32 marker. The exact depth-33 diagnostic remains checked in even though
its source chain is generated.

Remaining gaps are explicit: included Markdown is covered, but arbitrary
post-render HTML fragments are not; the existing `max_expanded_bytes` and
`max_include_expansions` guards lack normative numeric ownership in the
reviewed contract, so their large boundaries are not claimed here.

### C02 classification

The depth-32 success and depth-33 rejection are **Non-issue / packet drift**
where a contrary claim says the boundary is absent. The missing numeric
ownership for include expansion budgets is **Insufficient evidence**, not a
product defect.

## C03 — XML sitemap

### Case map

| Retained input | Verifier case | Expected result and assertion |
|---|---|---|
| `c03-sitemap/content`, trailing URL | `c03-trailing` | Exit 0; exact `expected/meta/discovery.xml`; full target tree |
| Same content, no trailing slash | `c03-no-trailing` | Exit 0; same sitemap golden; tree equals trailing case |
| Same content, trailing repeat | `c03-trailing-repeat` | Exit 0; full tree equals first trailing run |
| Relative, `mailto:`, query, malformed authority URLs | `c03-invalid-relative`, `c03-invalid-mailto`, `c03-invalid-query`, `c03-invalid-malformed-authority` | Exit 2; exact `expected/invalid-site-url.stderr`; no output target |

The sitemap golden asserts four deterministic escaped absolute URLs, Unicode
path percent-encoding, nested paths, draft exclusion, and exclusion of the
copied asset. The repeat comparisons cover both slash normalization and
artifact determinism. The invalid URL matrix covers relative, non-HTTP(S),
query-bearing, and malformed-authority shapes.

The 50,000-URL and 50 MiB limits remain covered by focused sitemap-module
tests, not by this small CLI corpus. That is the explicit C03 integration gap.

### C03 classification

No **Confirmed defect** or **Likely defect** was found. The CLI returns the
required exit-2 class for malformed sitemap URLs, but attributes the usage
diagnostic to `--input`; the exact observed output is retained in the
snapshot. That is the required **Documented limitation** for CLI bad-flag
attribution, not a sitemap publication defect.

## C04 — RSS 2.0

### Case map

| Retained input | Verifier case | Expected result and assertion |
|---|---|---|
| `c04-rss/content`, limit 2 | `c04-feed-2` | Exit 0; exact `expected/feed-limit-2.xml` |
| Same content, limit 3 | `c04-feed-3` | Exit 0; exact `expected/feed-limit-3.xml` |
| Same content, limit 4 | `c04-feed-4` | Exit 0; exact `expected/feed-limit-4.xml` |
| Same content, limit 3 repeat | `c04-feed-3-repeat` | Exit 0; byte-equal to `c04-feed-3` |
| `cases/missing-summary` | `c04-missing-summary` | Exit 1; exact `expected/stderr.txt`; no feed file |
| Limits 0 and 501 | `c04-invalid-limit-0`, `c04-invalid-limit-501` | Exit 2; exact `expected/invalid-value.stderr`; no feed |
| Missing site/title/description | `c04-missing-site/title/description` | Exit 2; exact `expected/missing-value.stderr`; no feed |

The feed cases cover N-1/N/N+1 limits, timestamp ordering and tie ordering,
draft and summary-only exclusion, XML escaping, metadata, and repeatability.
The retained content does not materialize the 500-item or RSS-size ceilings;
those are explicit integration gaps.

### C04 classification

No **Confirmed defect** or **Likely defect** was found. The CLI's same
best-effort bad-flag attribution remains the **Documented limitation** recorded
under C03; all tested usage cases return exit 2.

## C08 — parser limits and Unicode

### Retained CLI case map

| Retained input | Verifier case | Expected result and assertion |
|---|---|---|
| `c08-parser-unicode/content` | `c08-valid` | Exit 0; exact `expected/graph.json`; manifest/build report exist; repeat graph and manifest |
| `cases/malformed-unicode` | `c08-malformed-unicode` | Exit 1; exact `expected/stderr.txt`; no graph/manifest |
| `cases/bom` | `c08-bom` | Exit 1; exact `expected/stderr.txt`; no graph/manifest |
| `fixtures/content/invalid` | `c08-invalid-utf8` | Exit 1; exact `expected/invalid-utf8.stderr`; no graph/manifest |

The valid graph preserves Unicode ids, title, summary, body, parent, and
relation bytes. The successful `build-report.json` contains its output path,
so the repeat check intentionally compares the deterministic graph and
manifest rather than treating that path-bearing report as a byte-stable
artifact. Failed IR runs retain only the intentional unsuccessful build
report.

### Focused parser assertions

The retained `src/parser.zig` tests now:

- free every allocated value/source or temporary list on each loop iteration;
- assert exact `EFRONTMATTER` or `EINVALIDUTF8` categories;
- assert representative `EFRONTMATTER` failures retain non-empty
  human-readable diagnostic detail without pinning mutable wording;
- assert accepted scalar, tag-token, source, and title lengths at the exact
  boundary;
- compare full Unicode strings and body bytes, preserving decomposed marks,
  CJK, emoji, and truncated-byte classification;
- avoid asserting diagnostic wording where the parser contract owns only a
  category.

The tested bounds are source 1 MiB, frontmatter 64 KiB, title 512, summary
1,024, id/parent 255, tag token 64, tag count 32, and relation count 16, each
with exact and +1 behavior where meaningful. The 32-field guard remains
unreachable under the closed eight-key grammar: duplicate recognized keys fail
before 32 and unknown keys fail immediately. That is **Insufficient evidence**,
not a confirmed parser defect.

## C01 — valid Textile HTML

Contract owner: `docs/contracts/textile-compatibility.md` (the bounded
compatibility subset only; no complete-Textile claim). Frontmatter stays
Boris-owned, and `--textile` is an explicit opt-in mode.

| Case ID | Contract owner | Fixture / declaration | Command | Expected exit | Expected artifact / diagnostic | Repeat | Classification | Remaining gap |
|---|---|---|---|---|---|---|---|---|
| `c01-valid` | textile-compatibility | `c01-textile/content` | `--textile --html … --quiet` | 0 | `expected/index.html` + `expected/guides-satellite.html` goldens | jobs 1 == 4; clean == incremental | Non-issue / packet drift | — |
| `c01-valid-jobs4` | textile-compatibility | same | `--textile --html … --jobs 4 --quiet` | 0 | tree equal to `c01-valid` | byte-identical | Non-issue / packet drift | — |
| `c01-valid-incr` | textile-compatibility | same | `--textile --html … --incremental --quiet` | 0 | tree equal to `c01-valid` (minus `.boris-cache`) | byte-identical | Non-issue / packet drift | — |
| `c01-frontmatter` | textile-compatibility + frontmatter | `cases/frontmatter/content` | `--textile --html …` | 1 | exact `EFRONTMATTER` snapshot; no target | — | Non-issue / packet drift | — |
| `c01-malformed-delimiter` | textile-compatibility | `cases/malformed-delimiter/content` | `--textile --html …` | 1 | exact `ETEXTILE` snapshot; no target | — | Non-issue / packet drift | — |
| `c01-malformed-incomplete-link` | textile-compatibility | `cases/malformed-incomplete-link/content` | `--textile --html …` | 1 | exact `ETEXTILE` snapshot; no target | — | Non-issue / packet drift | — |
| `c01-unsafe-link` | textile-compatibility | `cases/unsafe-link/content` | `--textile --html …` | 1 | exact `ETEXTILE` snapshot; no target | — | Non-issue / packet drift | — |
| `c01-unsupported-attributes` | textile-compatibility | `cases/unsupported-attributes/content` | `--textile --html …` | 1 | exact `ETEXTILE` snapshot; no target | — | Non-issue / packet drift | — |
| `c01-unsupported-blockcode` | textile-compatibility | `cases/unsupported-blockcode/content` | `--textile --html …` | 1 | exact `ETEXTILE` snapshot; no target | — | Non-issue / packet drift | — |
| `c01-unsupported-notextile` | textile-compatibility | `cases/unsupported-notextile/content` | `--textile --html …` | 1 | exact `ETEXTILE` snapshot; no target | — | Non-issue / packet drift | — |
| `c01-unsupported-table` | textile-compatibility | `cases/unsupported-table/content` | `--textile --html …` | 1 | exact `ETEXTILE` snapshot; no target | — | Non-issue / packet drift | — |
| `c01-include-in-textile` | textile-compatibility | `cases/include-in-textile/content` | `--textile --html …` | 1 | exact `ETEXTILE` snapshot; no target | — | Non-issue / packet drift | — |
| `c01-mixed` | textile-compatibility | `cases/mixed/content` (`a.textile` + `b.md`) | `--textile --html …` | 1 | exact mix-mode snapshot; no target | — | Non-issue / packet drift | — |
| `c01-mode-markdown-flag` | textile-compatibility | `cases/mode-markdown-flag/content` (`.md` + `--textile`) | `--textile --html …` | 1 | exact mix-mode snapshot; no target | — | Non-issue / packet drift | — |
| `c01-mode-textile-noflag` | textile-compatibility | `cases/mode-textile-noflag/content` (`.textile` without flag) | `--html …` | 1 | exact mix-mode snapshot; no target | — | Non-issue / packet drift | — |

The success tree covers headings, paragraphs, emphasis (`*`, `_`, `+`, `-`),
inline code, links (https, mailto, fragment, in-tree `./` destination),
Unicode, HTML escaping, blockquote, ul/ol, and satellite (parent) pages.
Proven: `--textile` does not change Markdown mode output, does not widen the
accepted frontmatter grammar (unknown key still `EFRONTMATTER`), rejects Boris
macros in Textile mode, and the bounded subset rejects tables, blockcode,
notextile, heading attributes, malformed delimiters, and unsafe/incomplete
link destinations. Jobs 1 vs 4 and clean vs incremental byte equality hold.

### C01 classification

No **Confirmed defect** or **Likely defect**. Unsupported Textile constructs
fail with exit 1 (content class) and exact diagnostics. Remaining gap: the
Textile subset is bounded; constructs outside it are rejected, and full
Textile-language compatibility is explicitly not claimed.

## C05 — layout precedence

Contract owner: `docs/contracts/templating-and-themes.md` §4.2 (exact id > most-specific glob > role > fallback; equal-specificity globs are ambiguous), `docs/contracts/cli.md` (layout flags, exit classes), `docs/contracts/multi-target-isolated-output.md` (per-target isolation).

| Case ID | Contract owner | Fixture / declaration | Command | Expected exit | Expected artifact / diagnostic | Repeat | Classification | Remaining gap |
|---|---|---|---|---|---|---|---|---|
| `c05-explicit` | templating-and-themes | `layouts/exact.html` | `--html … --html-layout exact.html --quiet` | 0 | every page carries `C05-EXACT` marker | — | Non-issue / packet drift | — |
| `c05-rule-id` | templating-and-themes | `layouts/global.html` + `target.html` | `… --html-layout global.html --layout-rule default id:reference/config target.html --quiet` | 0 | `reference/config.html` `C05-TARGET`; `index.html` `C05-GLOBAL` | — | Non-issue / packet drift | — |
| `c05-rule-glob` | templating-and-themes | `glob.html`, `deep.html` | `… --layout-rule default glob:guides/* glob.html --layout-rule default glob:reference/deep/* deep.html --quiet` | 0 | g1 `C05-GLOB`, deep `C05-DEEP`, config `C05-GLOBAL` | — | Non-issue / packet drift | — |
| `c05-rule-role` | templating-and-themes | `role.html` | `… --layout-rule default role:trunk role.html --quiet` | 0 | `index.html` `C05-ROLE`; satellite `C05-GLOBAL` | — | Non-issue / packet drift | — |
| `c05-theme` | templating-and-themes | `theme/layouts/main.html` | `… --theme c05-layout-precedence/theme --quiet` | 0 | every page `C05-THEME` | — | Non-issue / packet drift | — |
| `c05-multi` | multi-target-isolated-output | two targets | `… --target one=… --target two=… --target-layout one=exact.html --target-layout two=global.html --quiet` | 0 | `one/index.html` `C05-EXACT`; `two/index.html` `C05-GLOBAL` | — | Non-issue / packet drift | — |
| `c05-missing-layout` | cli.md (exit 3) | `layouts/nope.html` absent | `… --html-layout nope.html` | 3 | exact `expected/missing-layout.stderr`; no target | — | Non-issue / packet drift | — |
| `c05-missing-marker` | templating-and-themes | `layouts/nomarker.html` | `… --html-layout nomarker.html` | 1 | exact `expected/missing-marker.stderr`; no target | — | Non-issue / packet drift | — |
| `c05-duplicate-marker` | templating-and-themes | `layouts/dupmarker.html` | `… --html-layout dupmarker.html` | 1 | exact `expected/duplicate-marker.stderr`; no target | — | Non-issue / packet drift | — |
| `c05-ambiguous-glob` | templating-and-themes §4.2 | two equal-specificity globs | `… --html-layout global.html --layout-rule default glob:reference/* glob.html --layout-rule default glob:*/config target.html` | 2 | exact `expected/ambiguous-glob.stderr` (first 2 lines) | — | Non-issue / packet drift | output-path line trimmed from snapshot |
| `c05-incr-base` | templating-and-themes | generated `layouts/{global,target,glob}.html` | `--incremental` first publication into one reused target; `id:reference/config` exact beats `glob:reference/*` | 0 | `reference/config.html` `C05-TARGET`; `index.html` `C05-GLOBAL`; `.boris-cache/manifest.json` present | — | Non-issue / packet drift | — |
| `c05-incr-win` | templating-and-themes | edit winning `target.html` in place (same path) | `--incremental` rebuild into the same target | 0 | `reference/config.html` `C05-TARGET-V2`; `index.html` byte-identical to baseline | winning rebuild vs baseline index | Non-issue / packet drift | — |
| `c05-incr-lose` | templating-and-themes | edit only losing `glob.html` in place (same path) | `--incremental` rebuild into the same target | 0 | `reference/config.html` still `C05-TARGET-V2`, byte-identical to `c05-incr-win`; `index.html` unchanged | winning vs losing rebuild config | Non-issue / packet drift | — |

### C05 classification

No **Confirmed defect** or **Likely defect**. Precedence, ambiguity, marker
validation, theme sugar, and multi-target isolation all match contract text.
The `ambiguous-glob` snapshot deliberately retains only the first two lines;
the discarded `configured targets` block embeds the run's output directory, so
it is **Documented limitation** (unstable path) rather than evidence loss.

## C06 — cache and watch failure paths

Contract owner: `docs/contracts/watch-mode.md` §5 (content validation failures keep the watcher alive for author recovery), `docs/contracts/cli.md` (exit classes), `docs/contracts/diagnostics.md`, `docs/contracts/html-output.md`, `docs/contracts/content-local-assets.md`, `docs/contracts/xml-sitemap.md`, `docs/contracts/rendered-search.md`.

| Case ID | Contract owner | Fixture / declaration | Command | Expected exit | Expected artifact / diagnostic | Repeat | Classification | Remaining gap |
|---|---|---|---|---|---|---|---|---|
| `c06-noop` | html-output | `c06-cache-watch/content` | `--incremental` first publication, then two unchanged `--incremental` rebuilds into the same target | 0 | payload byte-identical to baseline snapshot; manifest present; two rebuild manifests byte-identical | payload + manifest | Non-issue / packet drift | — |
| `c06-source-edit` | html-output | edit `guides/g1.md` | `--incremental` baseline, then `--incremental` rebuild into same target | 0 | `g1.html` contains new body; `index.html` sibling byte-identical | sibling page | Non-issue / packet drift | — |
| `c06-source-delete` | html-output | delete `guides/g1.md` | `--incremental` baseline, then `--incremental` rebuild into same target | 0 | stale `guides/g1.html` removed | — | Non-issue / packet drift | stale prune needs prior manifest (see below) |
| `c06-include-edit` | html-output | edit `includes/frag.md` | `--incremental` baseline, then `--incremental` rebuild into same target | 0 | `index.html` contains `Fragment v2` | — | Non-issue / packet drift | — |
| `c06-include-missing` | diagnostics | delete `includes/frag.md` | fresh isolated target | 1 | exact `expected/include-missing.stderr`; no target | — | Non-issue / packet drift | isolated failure, not cache evidence |
| `c06-parse-failed` | diagnostics | add `bad.md` with unknown key | fresh isolated target | 1 | exact `expected/parse-failed.stderr`; no target | — | Non-issue / packet drift | isolated failure, not cache evidence |
| `c06-layout-dup` | templating-and-themes | `dup.html` | fresh isolated target | 1 | exact `expected/layout-dup-marker.stderr`; no target | — | Non-issue / packet drift | isolated failure, not cache evidence |
| `c06-theme` | content-local-assets | edit `theme/assets/theme.css` | `--incremental` baseline with `--theme`, then `--incremental` rebuild into same target | 0 | output `assets/theme.css` changes | — | Non-issue / packet drift | — |
| `c06-content-asset` | content-local-assets | edit `content/index.assets/style.css` | `--incremental` baseline, then `--incremental` rebuild into same target | 0 | output `index.assets/style.css` changes | — | Non-issue / packet drift | — |
| `c06-sitemap` | xml-sitemap | `status: draft` on `g1.md` | `--incremental` baseline, then `--incremental` rebuild into same target | 0 | sitemap replaced; draft page absent | — | Non-issue / packet drift | — |
| `c06-search` | rendered-search | body edit on `index.md` | `--incremental` baseline, then `--incremental` rebuild into same target | 0 | `_boris/search/search-index.json` changes | — | Non-issue / packet drift | — |
| `c06-watch` | watch-mode | `watch --html …` | start, edit source, SIGTERM | 0 | initial build; observed rebuild; clean exit 0 | — | Non-issue / packet drift | — |
| `c06-watch-fail` | watch-mode §5 | delete include while watching, restore in the same session | watch, delete, restore, SIGTERM | 0 | `error: rebuild failed: IncludeFailed. Waiting for correction...`; watcher stays alive; prior `site/index.html` byte-identical; corrected `Fragment v2` published by the same process; clean SIGTERM exit 0 | — | Resolved (W1) | — |
| `c06-watch-svg` | watch-mode §5 + content-local-assets | replace inert `content/index.assets/logo.svg` with an active `<script>` SVG while watching, restore a different inert SVG in the same session | watch, replace, restore, SIGTERM | 0 | EASSET diagnostic plus `Waiting for correction`; watcher stays alive; prior `site/index.html` and `site/index.assets/logo.svg` byte-identical; corrected SVG published by the same process; clean SIGTERM exit 0 | — | Resolved (W1/S1) | — |

### C06 classification

All cache, stale-removal, sitemap, search, and clean watch behaviors match
contract text on the exercised paths. The previously confirmed defect — a
failed include rebuild killing the watcher — is **resolved** by this branch:  `error.IncludeFailed` is now in the watch recoverable-error set
(`isRecoverableBuildError` in `src/watch.zig`), so the same-session case
(`c06-watch-fail`) proves the watcher survives the failed rebuild, keeps the
prior valid output byte-identical, and publishes the corrected content from
the same process (then SIGTERM exits 0). Unsafe-SVG content errors recover
consistently in watch mode too: `error.AssetUnsafeSvg` is in the same
recoverable set, and the `c06-watch-svg` case proves one uninterrupted
watcher process survives an author replacing an inert SVG with an active
`<script>` construct, keeps both the prior published HTML and SVG
byte-identical, and publishes a corrected inert SVG from the same session.
The CLI synthesizes a "default" target from `--html-dir`, so watch rebuilds
normally route through the multi-target aggregate; the raw single-target path
(empty target list) is covered by the in-process `src/watch.zig` regression.
The watch tests are bounded (20 s worst-case waits), terminate via SIGTERM
through the existing watcher shutdown path, and the exit trap now waits on
every retained watcher PID so no background Boris process survives an
assertion failure.

The executable cases distinguish **clean rebuild behavior**, **incremental
mode first publication** (the `-base` run: renders every page and writes
`.boris-cache/manifest.json`), **incremental rebuild using the prior
target/cache** (the `-reb` run into the same directory, asserted by the
prior-manifest check inside the rebuild helper), and **watch behavior**. The
source-delete case is deliberately an incremental baseline followed by an
incremental rebuild: stale HTML pruning operates on the prior manifest, so
a first incremental publication without a prior manifest would not prune
(observed; **Documented limitation**, not claimed as evidence). Failure-only
cases (missing include, bad frontmatter, duplicate layout marker) run on
fresh isolated targets and are not cited as cache-invalidation evidence.

## C07 — asset collisions and SVG policy

Contract owner: `docs/contracts/content-local-assets.md` §5 (EASSET content class; rejected SVG never emitted/inventoried; symlink and traversal prohibition), `docs/contracts/html-output.md`, theme asset inventory (theme.zig), `docs/contracts/xml-sitemap.md`, `docs/contracts/rendered-search.md`, and the SVG policy in `docs/changelog.d/262-active-svg-assets.md` (bounded construct list — no browser-security certification claim).

| Case ID | Contract owner | Fixture / declaration | Command | Expected exit | Expected artifact / diagnostic | Repeat | Classification | Remaining gap |
|---|---|---|---|---|---|---|---|---|
| `c07-svg-script` | SVG policy | generated `guides/intro.assets/t.svg` `<script>` | `--html …` | 1 | exact `expected/svg-script.stderr`; no target; no inventory | — | Resolved (S1) | — |
| `c07-svg-event-handler` | SVG policy | `onload` attribute | `--html …` | 1 | exact `expected/svg-event-handler.stderr`; no target; no inventory | — | Resolved (S1) | — |
| `c07-svg-javascript-url` | SVG policy | `javascript:` href | `--html …` | 1 | exact `expected/svg-javascript-url.stderr`; no target; no inventory | — | Resolved (S1) | — |
| `c07-svg-foreignobject` | SVG policy | `<foreignObject>` | `--html …` | 1 | exact `expected/svg-foreignobject.stderr`; no target; no inventory | — | Resolved (S1) | — |
| `c07-svg-iframe` | SVG policy | `<iframe>` | `--html …` | 1 | exact `expected/svg-iframe.stderr`; no target; no inventory | — | Resolved (S1) | — |
| `c07-svg-object` | SVG policy | `<object>` | `--html …` | 1 | exact `expected/svg-object.stderr`; no target; no inventory | — | Resolved (S1) | — |
| `c07-svg-doctype` | SVG policy | `<!DOCTYPE …>` | `--html …` | 1 | exact `expected/svg-doctype.stderr`; no target; no inventory | — | Resolved (S1) | — |
| `c07-svg-style-import` | SVG policy | `<style>@import url(…)</style>` | `--html …` | 1 | exact `expected/svg-style-import.stderr`; no target; no inventory | — | Resolved (S1) | — |
| `c07-svg-animate-onload` | SVG policy | `animate attributeName="onload"` | `--html …` | 1 | exact `expected/svg-animate-onload.stderr`; no target; no inventory | — | Resolved (S1) | — |
| `c07-svg-multi` | SVG policy | same `<script>` SVG, two targets (shared content root, so every target encounters it) | `--html … --target alpha=… --target beta=…` | 1 | EASSET diagnostic; no I/O summary; no final targets; no inventory | — | Resolved (S1) | — |
| `c07-valid` | SVG policy | inert Unicode/entity SVG | `--html … --quiet` | 0 | byte-identical copy; present in `_boris/proof/artifacts.json` | jobs 1 == 4; clean == incremental | Non-issue / packet drift | — |
| `c07-theme-page` | theme.zig AssetCollision | page `assets/index.md` + theme `assets/index.html` | `--theme …` | 1 | exact `expected/theme-page-collision.stderr`; no target | — | Non-issue / packet drift | — |
| `c07-symlink` | content-local-assets | symlinked `link.svg` | `--html …` | 1 | exact `expected/symlink-asset.stderr`; no target | — | Non-issue / packet drift | skipped if host cannot `ln -s` |
| `c07-traversal` | content-local-assets | `![alt](../secret.png)` | `--html …` | 1 | exact `expected/traversal-image.stderr`; no target | — | Non-issue / packet drift | — |
| `c07-sitemap` | xml-sitemap | `--sitemap-path guides/intro.html` | `--sitemap-path guides/intro.html --site-url …` | 2 | exact `expected/sitemap-content-collision.stderr` (first 2 lines) | — | Non-issue / packet drift | output-path line trimmed from snapshot |

### C07 classification

Collision ownership (page vs theme asset, sitemap vs page, symlink,
traversal) matches contract text and fails closed with no misleading
inventory. Accepted inert SVGs are copied byte-identically, inventoried, and
jobs/incremental-equal. The previously confirmed defect —
`EASSET`/`AssetUnsafeSvg` rejections exiting 3 (I/O class) instead of the
content-class exit 1 required by `content-local-assets.md` §5 and `cli.md` —
is **resolved** by this branch: `AssetUnsafeSvg` is now in the content-error
arm of `mapHtmlError` (`src/main.zig`) and in `isContentCompileFailure`
(`src/compile.zig`), so single-target and multi-target runs both exit 1 with
the exact EASSET diagnostic and **no** generic I/O summary line. The SVG
policy is recorded as the bounded construct list; no browser-security
certification is claimed. Structurally unreachable collisions (two theme
assets to one path, content asset vs page output, `_boris/` reserved paths)
are **Documented limitation** of the exact-equality model, not defects.

## Findings and remaining gaps

The two confirmed defects retained by the round-2 suite (W1 from C06 and S1
from C07) are **resolved by this branch**; their historical reproduction and
repair boundary are retained in the resolved-defects section below. The
active confirmed-defect list for this branch is **empty**. The first-round
follow-ups remain exactly classified:

1. **Insufficient evidence — include expansion budgets lack normative numeric
   ownership.** Assign contract ownership to the existing byte and expansion
   count guards before claiming those numeric boundaries.
2. **Insufficient evidence — the 32-field guard is unreachable under the closed
   grammar.** Clarify whether it is future-proofing and add a parser-only
   boundary test, or reframe/remove the guard.
3. **Documented limitation — CLI bad-flag attribution.** Sitemap/RSS value
   errors return the required usage exit but currently name `--input`;
   improving `findBadArg` is separate from publication output conformance.

### Follow-up observations (not expanded in this branch)

The watch recovery set remains closed on errors clearly owned by the watch
contract: `error.IncludeFailed` and `error.AssetUnsafeSvg` are recoverable
(author-correctable content validation failures), while hard filesystem and
system failures are not. Neighboring author-correctable content failures that
are still treated as unrecoverable by `isRecoverableBuildError` are recorded
as observations, not widened here: `error.ReferenceFailed` (missing wiki-link
target) and `error.AssetFailed` / `error.AssetMissing` (missing content-local
assets), plus the layout-loading content failures that `mapHtmlError` already
classifies as exit 1. The watch contract (§5) lists content validation
failures generically, so these are candidates for a future, separately scoped
repair; this branch does not silently broaden the recovery set.

## Resolved defects

Both defects retained by the round-2 suite are resolved by this branch. The
historical reproduction and the smallest repair boundary are retained here
for audit continuity; the executable evidence now asserts the corrected
behavior.

### W1 — watcher exits on failed include rebuild (resolved)

- **Historical reproduction:** `boris watch --html --input <content with
  {{include includes/frag.md}}> …`; wait for the initial build; delete
  `content/includes/frag.md`; the watcher previously printed `error: rebuild
  failed with unrecoverable I/O error: IncludeFailed` and exited (rc 1).
- **Contract expectation:** `docs/contracts/watch-mode.md` §5 requires content
  validation failures (including unresolved includes) to keep the watcher
  running so the author can fix the source and observe the corrected rebuild.
- **Repair:** `error.IncludeFailed` added to the recoverable-error set
  (`isRecoverableBuildError` in `src/watch.zig`). Real filesystem/system
  failures (missing content roots, access errors, watcher backend errors) are
  deliberately not recoverable and still terminate the process.
- **Same-session evidence:** the rewritten `c06-watch-fail` case starts one
  watcher, waits for the initial successful build, snapshots the valid
  `site/index.html`, deletes the include, observes the recoverable
  `IncludeFailed` diagnostic while the process stays alive, proves the prior
  published HTML is byte-identical, restores the include with changed content,
  waits for the same process to publish the corrected output, and then
  requires a clean SIGTERM exit 0. The case fails if Boris exits after the
  missing include or if recovery requires restarting the process.
- **Repair boundary:** only the watcher-lifetime contract. This repair does
  not claim whole-tree rollback, cross-volume atomicity, or
  concurrent-reader atomicity.

### S1 — active-SVG rejection exits 3 instead of 1 (resolved)

- **Historical reproduction:** publishing any content-local SVG in the bounded
  policy's rejected set (e.g. `<script>`, `onload`, `javascript:` URL,
  `<foreignObject>`, `<iframe>`, `<object>`, DOCTYPE, `@import`, or
  `animate attributeName="on*"`) previously exited 3 with
  `one or more HTML targets failed due to I/O or a system error`.
- **Contract expectation:** `docs/contracts/content-local-assets.md` §5 and
  `docs/contracts/cli.md` classify `EASSET` as a content validation failure
  (exit 1), and rejected SVG must never be emitted or inventoried.
- **Repair:** `error.AssetUnsafeSvg` added to the content-error arm of
  `mapHtmlError` (`src/main.zig`) whose structured diagnostic is already
  emitted, and to `isContentCompileFailure` (`src/compile.zig`) so the
  multi-target aggregate also stays content-class. No second generic
  content-error line is printed. For watch mode, `error.AssetUnsafeSvg` is
  also in the recoverable-error set (`isRecoverableBuildError` in
  `src/watch.zig`), so the same author-correctable content failure keeps the
  watcher alive in both the raw single-target and multi-target rebuild paths
  and recovers in the same process session.
- **Content exit 1 evidence:** every retained `c07-svg-*` case now requires
  exit 1, the exact EASSET diagnostic, no I/O summary line, no final HTML
  target, and no artifacts.json entry. `c07-svg-multi` proves the same for a
  multi-target run where a target encounters the unsafe SVG.
- **Repair boundary:** the SVG scanner, rejected construct list, accepted SVG
  behavior, diagnostic code/wording, asset copy semantics, and inventory
  ownership are unchanged.

## Reproduction and validation record

The complete verification set was run from the repository root with
repository-relative paths on the `codex/conformance-w1-s1-remediation` branch.
Final results:

| Command | Result |
|---|---|
| `zig fmt --check src/main.zig src/watch.zig src/compile.zig` | Exit 0; formatting clean. |
| `zig build test-publication-conformance` | Pass; every C01–C08 case, including the resolved W1 same-session watch lifecycle, the `c06-watch-svg` unsafe-SVG same-session recovery, and the resolved S1 SVG exit-1 matrix, passed. |
| `zig build test-publication-artifacts --summary all` | Pass. |
| `zig build test-publication-checks --summary all` | Pass. |
| `zig build test-publication-claims --summary all` | Pass. |
| `zig build test --summary all` | Pass; full unit suite. |
| `zig build --summary all` | Pass. |
| `./scripts/release-gate.sh` | Pass; `RELEASE GATE PASSED`. |
| `git diff --check` | Exit 0; no whitespace errors. |

Negative controls (each reverted before commit):

- Temporarily removing `error.IncludeFailed` from the recoverable set made the
  same-session `c06-watch-fail` case fail (the watcher exited after the failed
  include rebuild); restoring it returned the case to passing.
- Temporarily removing `error.AssetUnsafeSvg` from the recoverable set made the
  in-process single-target watch regression fail (the unsafe-SVG rebuild
  propagated as an unrecoverable error instead of recovering); restoring it
  returned the case to passing.
- Temporarily reverting the SVG exit mapping made `c07-svg-script` fail (exit 3
  with the I/O summary line instead of exit 1); restoring it returned the
  case to passing.

Additional required checks passed:

- Every claimed incremental sequence visibly reuses one output directory:
  each C06 scenario asserts the prior `.boris-cache/manifest.json` exists in
  the same `--html-dir` before each rebuild, and the C05 sequence rebuilds
  `c05-incr` three times with no fresh directory.
- No watcher process remains after a forced verifier failure: the exit trap
  sends SIGTERM and then `wait`s on every retained watcher PID before
  removing the workspace (verified with a forced mid-watch assertion).
- Two consecutive accepted runs of the whole verifier exited 0 and produced
  byte-identical captured run output under `cmp` (the watch tests are the only
  timing-sensitive section and are bounded to 20 s worst case with SIGTERM
  shutdown; the generated tree is removed by the exit trap, so determinism is
  proven on the captured stdout/stderr, which embeds no timestamps or paths).
- No generated output tree is tracked: every generated fixture lives under the
  fixed ignored `.zig-cache/publication-conformance/` tree, which the verifier
  removes on exit (including failure), and the watch SIGTERM path shuts down
  cleanly.
- The verifier ran successfully from a clean detached checkout of the branch.
- Production behavior changes are confined to the W1 and S1 repair boundaries
  in `src/watch.zig`, `src/main.zig`, and `src/compile.zig`; no production
  behavior outside W1/S1 changed. The rest of the branch changes only
  `scripts/verify-publication-conformance.sh`, the retained
  `docs/audits/publication-conformance/{c01,c05,c06,c07}-*/` fixture trees,
  this report, and the remediation changelog fragment.