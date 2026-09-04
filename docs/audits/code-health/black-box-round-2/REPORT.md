# Code-health: black-box binary round 2 — kit cold-start + CLI pass

**Card:** #808 — one-time run under the #807 code-health pass (gates #810–#813 closed)
**Kit:** built via `scripts/agent-pack.sh` from a clean detached worktree of the `main` tip
**Authority:** review only — no product-code changes on this card. Findings filed as individual issues (#904, #905); this report is the one-pass artifact, archived at campaign closure.

| Item | Value |
|---|---|
| Kit commit | `cbc9fa9fe3fc65b150e4fbec88ba2d0dbc9e37f6` (origin/main tip at round start) |
| Platform | Darwin-arm64 (`uname -s`-`uname -m`, matched against `MANIFEST.json`) |
| Zig | 0.16.0 |
| Compiler version | `boris/0.8.2` (`--version`; `--build-info` `vcsRevision: cbc9fa9f` matches the kit commit) |
| Kit artifacts | `boris-agent-kit-cbc9fa9fe3fc.tar.gz` + sidecar SHA-256, outside tracked product files (pre-approved temp scratch) |
| Worktree at build time | `git status --short` clean |

## Recipient verification (before executing anything)

```
$ shasum -a 256 -c boris-agent-kit-cbc9fa9fe3fc.tar.gz.sha256
boris-agent-kit-cbc9fa9fe3fc.tar.gz: OK
$ tar -xzf boris-agent-kit-cbc9fa9fe3fc.tar.gz
$ shasum -a 256 -c boris-agent-kit/SHA256SUMS        # run from the kit root
bin/boris: OK
bin/boris-package: OK
bin/boris-source-rag: OK
```

`MANIFEST.json`: platform `Darwin-arm64` (matches machine), Zig `0.16.0`, `dirty: false`, three binaries with per-binary digests. Note: `branch` is `""` — the kit was built from a detached worktree, which the manifest records honestly (non-issue; noted for manifest readers).

## Cold-start protocol (neutral prompt, binary-only discovery)

Recipient workspace was a fresh empty directory; the only inputs were the verified archive, `MANIFEST.json`, `SHA256SUMS`, and the kit `README.md` (in bounds per the protocol). No Boris docs or source were consulted during discovery.

**Onboarding report (deliverable):**

*Every command and what told me to run it:*

| Command | Attribution |
|---|---|
| `./bin/boris --help` | Kit README: "run the appropriate executable from bin/" (guesswork on which/what) |
| `boris init .` | `--help` Modes section |
| `boris --input content --html-dir dist --theme themes/boris` | `init`'s own next-steps output |
| `boris validate --input content --theme themes/boris` | `--help` + init's command list |
| `boris check --input content` | init next-steps |
| grep of built HTML for `href`/`rel` | my own verification of the deliverable |

*Anything the tool did unasked:*

- `init` ran a verification compile of the fresh tree and reported the page count ("verified: starter compiled 3 page(s)").
- `init` wrote two publication profiles (`boris.json`, `standard-site.json` — the latter with an explicit fake DID to replace).
- The build emitted `_boris/proof/` (artifacts/checks/claims/touches/proof-pack/index) and `_boris/search/search-index.json` without being asked.
- The starter content already exercises the full graph shape (trunk, satellites with `parent:`, wiki links, a `relations:` edge) and the theme ships the search client.

*Expected but not found (leads, classified below):*

- Passing `--html-dir`/`--sitemap` without `--theme` fails with the default layout path `themes/boris/layouts/main.html` — a file a cold-start workspace does not have unless `init` was run in the same root. Understandable (workspace-relative defaults) but a real cold-start trap; classified **Documented limitation** (the `--help` default is stated; `init`'s next-steps always pass `--theme`).
- No serve/preview surface outside `watch --serve` — minor; the kit README advertises `watch --serve`, classified **Non-issue**.
- `nostr plan` rejected every profile I first guessed (`standard-site` publication, then a `nostr`-only section) with named profile errors (`profile declares no nostr section`, `invalid publication profile: NostrRequiresPublication`) — good named diagnostics, but discovering the required combined shape (`publication` target + `nostr` section) took several attempts. Classified **Documented limitation** (profile contract is normative; CLI probes give named errors, not shape examples).

*Stuck for more than a minute:* the `nostr plan` profile shape (above) and the unnamed `conflicting options` rejections (finding 2 below). Nothing else.

**Outcome:** the required site was built and validated from binary discovery alone: 3 pages, wiki link resolved in HTML (`href="getting-started.html"`), semantic relation rendered (`rel=` attributes present), `validate` passed, `check` reported a healthy graph.

## CLI matrix (kit binary only; ≥6 groups; content tree: `docs/contracts/fixtures/archive-layout-audit`)

| # | Group | Representative commands (output pasted in round scratch, summarized here) | Exit | Result |
|---|---|---|---|---|
| 1 | Version/build-info | `boris --version` → `boris/0.8.2`; `boris --build-info` → JSON with `vcsRevision cbc9fa9f`; `boris-package --version` → `boris-package/0.8.2` exit 0 (regression: #787 stays fixed) | 0 | Pass |
| 2 | Build/compile | Fixture build with 2 `--layout-rule`s: 13 pages + `_boris/proof/*` + search index; id-selector won for root, `role:trunk` for trunks; repeat build `diff -rq` byte-identical; `--timings` JSON with non-zero per-phase counters (regression: #775 stays fixed) | 0 | Pass |
| 3 | Validate | `boris validate …` pass; `boris validate --watch` on a broken tree prints the structured `EREFERENCEMISSING` diagnostic and keeps watching, clean signal shutdown | 0/1 | Pass |
| 4 | Check/impact | `check`, `impact <id>`, `--format json` (full graph/nodes/edges/findings JSON); `--fail-on-unreferenced` → exit 1; `impact nonexistent` → exit 2 named error | 0/1/2 | Pass |
| 5 | Exports | `--out` IR (manifest/graph/completion/build-report), `--rag` (working-1.md + manifest), `--context` (bundle/graph/pages), `--llms` (hierarchical llms.txt), `--sitemap` (with `--site-url`), `--rss` standalone | 0 | Pass |
| 6 | Plan/evidence | `boris plan --profile` normalized plan JSON; `standard-site plan`/`records`/`verify` offline (verify mismatch → structured result + exit 8, see finding 3); `nostr plan` named profile errors; proof `artifacts.json` with digests inspected | 0/2/8 | Pass (with findings) |
| 7 | Watch/serve lifecycle | `watch --watch-json` NDJSON: `hello` → `build-started` → `build-succeeded` (pages_written, duration) → `watcher-started` → `serve-started` (URL + `__boris/` helper) → `watch-stopped` on signal; `watch --serve` served `archive.html` (HTTP 200) + reload helper page | 0 | Pass |
| 8 | Failure paths | Missing content dir → exit 3 `content root "nosuchdir" not found…` + remediation (regression: #779 stays fixed); unknown flag → exit 2 **misattributed** (finding 1); `--site-url` alone → exit 2 generic (finding 2); broken wiki link → exit 1 `EREFERENCEMISSING` with fix hint | 1/2/3 | Findings filed |

## Findings

1. **Confirmed defect — filed [#904](https://github.com/drawmeanelephant/boris/issues/904).** Unknown-option diagnostic names the first non-exempt argv token, not the offending flag (`--input fixture/content --bogus-flag` → "unknown option: --input"). Reproduced on the kit binary and a source build at `cbc9fa9f`. Low severity, diagnostic quality.
2. **Likely defect — filed [#905](https://github.com/drawmeanelephant/boris/issues/905).** Two intentional conflicts (`--site-url` without `--rss`/`--sitemap`; `nostr plan --out`) exit 2 with the generic unnamed "conflicting options" message and are absent from `--help`'s Conflicts list. Low severity.
3. **Documented limitation.** `standard-site verify` mismatch exits 8; `--help`'s exit-code line lists only 0/1/2/3. Exit codes 4–9 for the standard-site family are normative in `docs/contracts/diagnostics.md` and `docs/contracts/standard-site.md` (and tested at `src/main.zig:3121`), so the contract is the authority — the help one-liner is a summary. Not actionable in this round.
4. **Documented limitation.** Cold-start default-layout trap and `nostr plan` profile-shape discovery friction (see cold-start report). Profile errors are named and remediation-hinted; the friction is in discovering the combined required shape, not in a wrong message.
5. **Non-issue.** `check` reports every page `unreferenced` on a tree with no wiki/doc links (reference edges only; parent edges don't count) — by design, and edge counts make it self-explaining.
6. **Non-issue.** Kit manifest `branch: ""` for a detached-worktree build — recorded honestly; worth a footnote for manifest readers, not a defect.
7. **Non-issue (regression).** #775 (`--timings` zero counters), #779 (missing path in ContentDirMissing), #786/#787 (auxiliary binaries `--version` exit 0) all verified fixed on this kit.

**Clean-report statement:** 8 command groups exercised, every material observation classified above; two actionable findings filed individually (#904, #905) with repro against the kit binary and a source build; no other defects found.
