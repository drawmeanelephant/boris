# Code-health audit report — CLI surface and diagnostics

**Card:** #814 (milestone [Code health pass](https://github.com/drawmeanelephant/boris/milestone/2), epic #807)
**Authority:** review only — no product-code changes on this card. Findings
filed individually: #872, #873 (Confirmed), #874 (Likely). #867 (filed from
card #813) sits in this card's locus and is cited, not re-filed.
**Commit audited:** `main` @ `e1e646d4` (branch `audit/814-cli-diagnostics`)
**Zig:** 0.16.0 (homebrew), macOS arm64 (darwin)
**Gate:** `zig build test` green before probes and re-run green after (exit 0).

## Setup

- Fresh branch `audit/814-cli-diagnostics` from `origin/main` tip `e1e646d4`;
  `git status` clean except the report itself.
- `zig build test` → exit 0 before any probe work; re-run exit 0 after.
- Black-box probes: `zig build` binary `zig-out/bin/boris` against a
  `boris init`-scaffolded tree in `/var/folders/.../T/opencode/q1-exits`
  (sibling dirs `q1-exits` … `q6-plan`); exit codes and full output below.
- Contracts read first (normative): `docs/contracts/cli.md`,
  `diagnostics.md`.
- Locus files read in full: `src/cli.zig` (4569; all functions through line
  2761, remainder is tests), `src/main.zig` (3700; non-test surface through
  3400), `src/init.zig` (488), `src/diag.zig` (371), `src/diagnostic.zig`
  (110). Drift checked both directions.

## Falsification table

| # | Probe | Commands (abridged) | Result | Classification | Evidence |
|---|-------|---------------------|--------|----------------|----------|
| Q1a | Exit class 0 (success) | `boris init`; `boris --quiet` | exit 0, dist built | Non-issue | cli.md exit table; diagnostic.zig ExitCode |
| Q1b | Exit class 2 (usage) | `boris --no-such-flag` | `error: unknown option: --no-such-flag (try --help)` + one synopsis line, exit 2 — short per #777 | Non-issue | cli.zig:2700-2716 (runArgs), main.zig:137-153 (reportUsage) |
| Q1c | Exit class 1 (content) | `bogus-key:` frontmatter page | `EFRONTMATTER: bad.md:2:1: unsupported frontmatter key [remediation]`, exit 1 | Non-issue | diag.zig:238-272 text form; mapHtmlError content branch |
| Q1d | Exit class 3 (I/O) | renamed-away `content/` | HTML: `content root "content" not found or not a directory` + remediation, exit 3; IR: `error: EIO: content root "content" not found or not a directory [Create the content directory or pass --input=DIR]`, exit 3 | Non-issue — #779 parity holds; both paths name the probed root with matching wording | main.zig:2955-2959; pipeline EIO diagnostic; diagnostics.md rule 5 |
| Q2a | Bare `standard-site` → family list, not full help | `boris standard-site` | `error: standard-site requires a subcommand (try: plan, records, verify, login, sessions, logout, publish, smoke)` + family list only, exit 2 | Non-issue | cli.md:36-38; cli.zig:921-940; main.zig reportUsage family branch |
| Q2b | `standard-site --help` → family list, exit 0 | `boris standard-site --help` | family list on stderr, exit 0, stdout empty | Non-issue | cli.zig:2681-2689 |
| Q2c | `init --help` narrow help, exit 0 | `boris init --help` | init-specific help, exit 0 | Non-issue | cli.md:117-118; cli.zig:2467-2492 |
| Q2d | `--version` / `--build-info` stdout machine surface | `boris --version`; `boris --build-info` | `boris/0.8.2` one line; `{"format": "boris-build-info", "schemaVersion": "1", "version": "boris/0.8.2", "vcsRevision": "e1e646d4"}`, both exit 0 | Non-issue | cli.md §Version query/§Build info; main.zig:67-135 |
| Q2e | Help-text drift vs cli.md vs behavior | `--help` conflict lines vs cli.md vs binary | `validate --profile` (also check/impact) → exit 2 but documented nowhere; help's validate conflict line omits `--refresh-evidence` (cli.md documents it) and adds `--out` (cli.md does not) | **Confirmed defect → #873** | cli.zig:1823-1844; cli.md:89-97; cli.zig:2392-2397 |
| Q3 | `ContentDirMissing` HTML-vs-IR parity (#779) | missing `content/`, both modes | wording matches exactly on both paths (see Q1d), both exit 3 | Non-issue | diagnostics.md rule 5 |
| Q4 | Layout-marker enum diagnostics (#737) | layouts missing `{{content}}`, duplicate `{{toc}}`, unknown `{{nope}}`, `{{nav depth=0}}` | stderr names each condition with per-code remediation (`ELAYOUTUNKNOWNMARKER` remediation enumerates every accepted marker); exit 1; `validate --report r.json` carries the structured object with exact key order `severity, code, message, remediation, sourcePath, line, column, id`, `errorCount: 1`, `ok: false`, `vcsRevision` present | Non-issue | diagnostics.md §HTML-path report; diag.zig:137-148; compile.zig loadLayoutsForPlan; html_report schema |
| Q5a | Foreign session-family flags on compiler commands | `boris --quiet --did …` / `--prune` / `--namespace` / `--source-commit` / `--dist` / `--handle` | all exit 0, silently ignored | **Confirmed defect → #872** | cli.zig:1269-1335, 1818-1881; contrast `--bundle` on build → exit 2 |
| Q5b | Conflict-form attribution vs #764 | `plan --profile p --timings`; `validate --profile p` | generic `conflicting options (try --help)` although the offending pair is unambiguous (contract names `plan --timings` explicitly); check/impact×HTML-selector arm does name pairs | **Likely defect → #874** | cli.zig:1530-1545, 1823-1830, 2533-2542; cli.md #764 paragraph |
| Q6a | `plan --timings` rejected (exit 2), stdout protected | `boris plan --profile p.json --timings` | exit 2, no plan JSON emitted | Non-issue (code/class); the message form is #874 | cli.md §stdout machine surface; cli.zig:1536-1545 |
| Q6b | `--timings` appended on failed run | failing page + `--timings` | timings JSON emitted to stdout despite exit 1, phases show what ran | Non-issue | cli.md §Timing report ("including failed runs"); main.zig:298-310 |
| Q6c | `init` into non-empty dir | `boris init <non-empty>` | `error: target directory is not empty; refusing to overwrite an existing site`, exit 2 | Non-issue (usage class; cli.md states the precondition, not the code) | init.zig:225-238 |
| Q6d | `impact` nonexistent id | `boris impact no-such-id --input …` | `error: impact target not found: no-such-id`, exit 2 | Non-issue (cli.md usage row covers "invalid ID"; the query resolves to nothing, no content compiled) | main.zig:2197-2200 |
| W1 | Duplicate-selector blame misattribution | `--layout-rule` twice + `--html-layout` | blames `--html-layout` (present once) — already filed from card #813 | Already filed → #867 (in this locus; cited, not re-filed) | cli.zig:2073, 2649-2661 |
| W2 | Exit-code enum vs contract | reading + unit run | `ExitCode` 0–9 matches cli.md/diagnostics.md tables 0–3 + standard-site family 4–9; `FailureClass` maps 0/1/2/3; unit tests lock values | Non-issue | diagnostic.zig:20-54; main.zig:3112-3122 |
| W3 | Diagnostic text form vs contract grammar | reading + Q1/Q4 output | content diagnostics follow `severity: CODE: path:line:col: message [remediation]`; null line/col form also present; layout-load prose lines embed the Zig error name (`LayoutMissingMarker`) instead of the stable code spelling — the structured report object is exact, so the machine surface conforms | Non-issue (prose wrapper vs structured object; both name the same condition) | diag.zig:238-272; compile.zig loadLayoutsForPlan print; Q4 report JSON |
| W4 | stdout machine-surface closed set | reading + Q2d/Q6b | `--version`, `--build-info`, `--timings`, plan/nostr/recipe-scale/standard-site artifacts on stdout; build/validate/check/impact/watch/init leave stdout empty; analysis without `--report` goes to stderr | Non-issue | cli.md §stdout machine surface; main.zig runIntelligence (stderr print), runRecipeScale/Plan (stdout) |
| W5 | `--out` re-ownership | reading | nostr sign/publish and recipe-scale re-own `--out` as artifact path (parseNostrFlags/parseRecipeScaleFlags run before parsePathFlags); standard-site maps `saw_out` to the four artifact outputs and rejects it on login/logout/sessions/smoke | Non-issue | cli.zig:1045-1056, 1058-1071, 1790-1804 |
| W6 | `init` determinism + self-verify | reading + unit run | fixed file table, refuse-non-empty, probe compile + removal, outside-workspace skip; unit `materialized starter compiles and the probe cleans up after itself` green | Non-issue | init.zig:195-389, 425-488 |

## Probe transcripts (full output)

### Q1 — exit-code classes

```text
$ boris --quiet                      # scaffolded site
exit=0
$ boris --no-such-flag
error: unknown option: --no-such-flag (try --help)
usage: boris <command> [options] (run boris --help for the full option list)
exit=2
$ boris --quiet                      # content/bad.md with `bogus-key: x`
error: EFRONTMATTER: bad.md:2:1: unsupported frontmatter key [Fix the frontmatter or encoding for this file]
error: content or layout failure: ParseFailed
exit=1
$ boris --quiet                      # content/ moved away (HTML path)
error: content root "content" not found or not a directory
remediation: create the content directory or pass --input=DIR
exit=3
$ boris --out irout --quiet          # same tree, IR path
error: EIO: content root "content" not found or not a directory [Create the content directory or pass --input=DIR]
exit=3
```

### Q2 — help / family list / version / build-info

```text
$ boris standard-site
error: standard-site requires a subcommand (try: plan, records, verify, login, sessions, logout, publish, smoke)
Boris Standard.site — Atmosphere publication (explicit; never implicit)
Usage: boris standard-site <command> [options]
  ... family list only (no compiler flags) ...
exit=2
$ boris standard-site --help   # same family list, exit=0
$ boris init --help            # narrow init help, exit=0
$ boris --version
boris/0.8.2
exit=0
$ boris --build-info
{"format": "boris-build-info", "schemaVersion": "1", "version": "boris/0.8.2", "vcsRevision": "e1e646d4"}
exit=0
$ boris plan --profile p.json --timings
error: conflicting options (try --help)
exit=2
```

### Q4 — layout-marker diagnostics + report shape

```text
$ boris --quiet --html-layout layouts/missing.html
error: target 'default' failed to load layout layouts/missing.html: LayoutMissingMarker [Add the required {{content}} (and any other referenced slot) marker to the layout template]
exit=1
# dup/unknown/navdepth variants print LayoutDuplicateMarker /
# LayoutUnknownMarker (remediation enumerates every accepted marker) /
# LayoutInvalidNavMarker, all exit=1
$ boris validate --quiet --html-layout layouts/missing.html --report r.json
exit=1 ; r.json:
{
    "schemaVersion": "html-build-report-0.2.0",
    "compilerId": "boris/0.8.2",
    "vcsRevision": "e1e646d4",
    "ok": false,
    "contentRoot": "content",
    "outDir": "dist",
    "errorCount": 1,
    "diagnostics": [
        {
            "severity": "error",
            "code": "ELAYOUTMISSINGMARKER",
            "message": "failed to load layout layouts/missing.html: LayoutMissingMarker",
            "remediation": "Add the required {{content}} (and any other referenced slot) marker to the layout template",
            "sourcePath": "layouts/missing.html",
            "line": null,
            "column": null,
            "id": null
        }
    ]
}
```

### Q5 — foreign flags / conflict attribution

```text
$ boris --quiet --did did:plc:aaaaaaaaaaaaaaaaaaaaaaaa ; echo exit=$?   # 0
$ boris --quiet --prune ; echo exit=$?                                  # 0
$ boris --quiet --namespace n ; echo exit=$?                            # 0
$ boris --quiet --source-commit c ; echo exit=$?                        # 0
$ boris --quiet --dist d ; echo exit=$?                                 # 0
$ boris --quiet --handle x ; echo exit=$?                               # 0
$ boris --quiet --bundle b.json
error: conflicting options (try --help)
exit=2
$ boris plan --profile p.json --timings
error: conflicting options (try --help)
exit=2
$ boris validate --profile p.json --quiet
error: conflicting options (try --help)
exit=2
```

### Q6 — timings on failure / init guard / impact id

```text
$ boris --quiet --input … --timings        # page with bogus frontmatter
{"format": "boris-timings", "schemaVersion": "1", "mode": "html",
 "phases": {"scan": 768041, "parse": 1087333}, ...}
exit=1                                     # report appended despite failure
$ boris init <non-empty-dir>
error: target directory is not empty; refusing to overwrite an existing site
exit=2
$ boris impact no-such-id --input … --quiet
error: impact target not found: no-such-id
exit=2
```

## Findings

1. **#872 Confirmed defect (low):** session-family flags (`--did`, `--handle`,
   `--app-password`, `--prune`, `--source-commit`, `--dist`, `--namespace`,
   `--surface-url`, `--indexer`, `--session-root`) are silently accepted and
   ignored on compiler commands (build/validate/check/impact/watch/nostr),
   while sibling family flags (`--bundle`, `--key-stdin`, `--id`,
   `--factor`) are rejected with exit 2. Locus `src/cli.zig:1269-1335`,
   `src/cli.zig:1818-1881`.
2. **#873 Confirmed defect (low, doc drift):** `--profile` is rejected on
   validate/check/impact (exit 2) but documented nowhere (cli.md validate
   paragraph and the `--help` conflict matrix both omit it); the help's
   validate conflict line also omits `--refresh-evidence` (documented in
   cli.md, enforced in code) and adds `--out` (not in cli.md). Locus
   `src/cli.zig:1823-1844`, `src/cli.zig:2392-2397`, `docs/contracts/cli.md:89-97`.
3. **#874 Likely defect (low):** single-cause conflict rejections print the
   generic `conflicting options (try --help)` although the offending pair is
   unambiguous — `plan --timings` is named by the contract itself, and the
   validate/check/impact `--profile` arm has one candidate pair; contrast the
   check/impact×HTML-selector arm which records both tokens (#764). Locus
   `src/cli.zig:1530-1545`, `1823-1830`, `2533-2542`.

Previously filed in this locus (cited, not re-filed): **#867** — duplicate
`--layout-rule` selector usage error blames an unrelated flag via the
`findBadArg` fallback (card #813).

Non-issue observations recorded for the record (no action):

- Exit classes 0/1/2/3 match the contract tables end to end (Q1), including
  #777 brevity (cause line + one synopsis) and the standard-site family-list
  exception (Q2a).
- `ContentDirMissing` HTML-vs-IR wording parity (#779) holds exactly; both
  paths name the probed root and the create-or-`--input` remediation (Q1d/Q3).
- Layout-marker diagnostics (#737) match `diagnostics.md`: stable codes,
  per-code remediation (unknown-marker remediation enumerates the full closed
  slot set), content-class exit 1, and the `html-build-report-0.2.0` object
  with exact key order and `vcsRevision` (Q4). The stderr prose line embeds
  the Zig error name rather than the stable code; the structured object is
  the conformant surface (W3).
- `plan --timings` rejection, `--timings` on failed runs, `--version` /
  `--build-info` short-circuits, and the stdout closed set all conform
  (Q2d, Q6a, Q6b).
- `impact` nonexistent id exits 2 ("invalid ID" in the cli.md usage row;
  nothing compiled) — defensible reading, no action (Q6d).
- `init` non-empty-dir refusal exits 2 (usage); cli.md states the
  precondition without naming a code — consistent with the usage class (Q6c).
- `init` materialization is byte-deterministic, refuses to clobber, removes
  partial trees, self-verifies through the real pipeline, and skips the probe
  honestly outside the workspace (W6).

## Exit checklist

- [x] 2 contracts read before the locus files
- [x] 5 locus files read in full; drift checked both directions
- [x] ≥4 falsification probes (6 probe families Q1–Q6, all black-box binary runs), ≥3 black-box: satisfied
- [x] Every material observation classified exactly once
- [x] Findings filed individually: #872, #873 (Confirmed), #874 (Likely); #867 cited
- [x] `zig build test` green before and after probe work (exit 0 both runs)
- [x] Report PR targeting `main` (this PR)
- [x] Close-out comment posted on #814 with the mandated template
