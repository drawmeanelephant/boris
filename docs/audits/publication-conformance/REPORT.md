# Publication conformance evidence: C02, C03, C04, and C08

Date: 2026-08-01
Base: `afterparty` at `0ac7ace5df98dd9d370ce827862c2060642059df`
Evidence branch: `codex/publication-conformance-fixtures`
Pull request: #287

## Authority and scope

This is an evidence-and-fixture pass for the requested publication-conformance
areas. Normative authority was resolved in this order: the relevant contracts
under `docs/contracts/`, current executable behavior, focused tests, and the
retained black-box evidence. No `src/` production behavior changed. The
source change in `src/parser.zig` is test-only; `build.zig`, CI, the verifier,
fixtures, snapshots, and report are verification infrastructure.

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

- reads retained fixtures and `c02-includes-fragments/depth-cases.tsv`;
- generates only the depth-32 and depth-33 source trees under the fixed,
  ignored `.zig-cache/publication-conformance/` tree;
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
| C02 includes/fragments | `c02-includes-fragments/cases/` plus `depth-cases.tsv` | `c02-01`–`c02-09`, `c02-depth-32`, `c02-depth-33` |
| C03 sitemap | `c03-sitemap/content/`, sitemap golden, CLI snapshots | `c03-trailing`, `c03-no-trailing`, `c03-invalid-*` |
| C04 RSS | `c04-rss/content/`, feed and CLI snapshots | `c04-feed-2/3/4`, `c04-missing-*`, `c04-invalid-*` |
| C08 parser/Unicode | `c08-parser-unicode/` plus repository invalid-UTF-8 corpus | `c08-valid`, `c08-invalid-*` |

## C02 — includes and heading fragments

### Generated depth declaration

`c02-includes-fragments/depth-cases.tsv` retains the requested depth, title,
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
| `depth-cases.tsv: depth-32` | `c02-depth-32` | Generated 32-level chain, exit 0; exact `cases/10-depth-32/expected/index.html` |
| `depth-cases.tsv: depth-33` | `c02-depth-33` | Generated 33-level chain, exit 1; exact `cases/11-depth-33/expected/stderr.txt`; no final HTML artifact |

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

## Findings and remaining gaps

The three current follow-ups remain exactly classified:

1. **Insufficient evidence — include expansion budgets lack normative numeric
   ownership.** Assign contract ownership to the existing byte and expansion
   count guards before claiming those numeric boundaries.
2. **Insufficient evidence — the 32-field guard is unreachable under the closed
   grammar.** Clarify whether it is future-proofing and add a parser-only
   boundary test, or reframe/remove the guard.
3. **Documented limitation — CLI bad-flag attribution.** Sitemap/RSS value
   errors return the required usage exit but currently name `--input`;
   improving `findBadArg` is separate from publication output conformance.

No item above is inflated into a **Confirmed defect** or **Likely defect**.

## Reproduction and validation record

The complete verification set is run from the repository root with repository-
relative paths. The final PR description records the exact command output for:

```bash
zig fmt --check build.zig src/*.zig
zig build test-publication-conformance
zig build test --summary all
zig build --summary all
./scripts/release-gate.sh
git diff --check
```

It also records the clean-checkout run, deliberate golden mutation failure,
repeat run, changed-file count, absence of committed generated output, and
the fact that no production behavior changed. The formatter command reports
the same pre-existing unformatted files on the base worktree; touched
`build.zig` and `src/parser.zig` are formatted and no formatter-only
production changes are included.

PR #286 merged as `0ac7ace5df98dd9d370ce827862c2060642059df` while this
revision was in progress. The existing branch is being rebased onto that
latest `afterparty` tip before the final validation record and push.
