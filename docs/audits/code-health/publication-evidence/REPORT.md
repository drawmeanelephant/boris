# Code-health audit report — publication profile, checks, and evidence

**Card:** #817 (milestone [Code health pass](https://github.com/drawmeanelephant/boris/milestone/2), epic #807)
**Authority:** review only — no product-code changes on this card. Findings
filed individually: #884, #885 (Confirmed, medium), #886, #887, #889
(Confirmed, low), #888 (Confirmed, trivial).
**Commit audited:** `main` @ `e1e5da84` (branch `audit/817-publication-evidence`)
**Zig:** 0.16.0, macOS arm64 (darwin)
**Gate:** `zig build test` green before probes and re-run green after (exit 0).

## Setup

- Fresh worktree of the `main` tip `e1e5da84`; `git status` clean except this
  report. `zig build test` → exit 0 before any probe work; re-run exit 0 after.
- Black-box binary: `zig-out/bin/boris` (boris/0.8.2, vcs `e1e5da84`) against
  scratch trees under `/var/folders/.../T/opencode/` (`p817-static`,
  `p817-minimal`) plus the repository's own content and the checked-in nostr
  fixture profile.
- Schema validation: Ajv CLI 5, Draft 2020-12 (`npx ajv-cli`), against the
  published schemas in `docs/contracts/schemas/`.
- Contracts read first (normative): `publication-profile.md`,
  `publication-plan.md`, `publication-artifacts.md`, `publication-checks.md`,
  `publication-claims.md`, `publication-touches.md`,
  `publication-proof-pack.md`, plus `publication-model.md` for claim
  ownership.
- Locus files read around the probe paths (not exhaustively re-prosed):
  `src/publication_profile.zig`, `src/publication_plan.zig`,
  `src/artifact_inventory.zig`, `src/publication_checks.zig`,
  `src/publication_claims.zig`, `src/publication_touches.zig`,
  `src/publication_proof_pack.zig`. Drift checked both directions.

## Falsification table

| # | Probe | Commands (abridged) | Result | Classification | Evidence |
|---|-------|---------------------|--------|----------------|----------|
| P1a | `static_file` through inventory | `boris build --html-dir dist --html-layout … --static-dir static` | exit 0; `robots.txt` + `.well-known/security.txt` copied; inventory records `kind=static-file, producer=static-files, semantics=static, advertised=null, required=true` | Non-issue — inventory half of #805/#806 agrees with the artifacts contract | artifacts.json (transcript T1) |
| P1b | `static_file` through plan | profile with `"static": {"dir": "static"}` → `boris plan --profile boris.json` | exit 0; plan carries `projections.static.dir`; published `publication-plan-1.schema.json` declares/`requires` the `static` projection | Non-issue | plan output (T1); schema `$defs/static` |
| P1c | `static_file` through checks | same target, read `checks.json` + `touches.json` | artifact-integrity subjects include the static files (eligible 5/5); rendered-html supporting scope covers all committed records — supporting digest **independently recomputed** from raw inventory bytes matches; static files get subject→integrity and supports→rendered-html edges, none to rendered-search | Non-issue — all three layers agree on kind handling | checks.json/touches.json (T1) |
| P2 | Claim/check trace (claim-vs-verification boundary) | real build → `claims.json`; mechanically re-verify bindings with sha256 | 3 claims, each `evidence.check_id` = positional check id; `checks_report_sha256` == sha256(exact checks.json bytes); `claims.publication_checks.sha256` == sha256(checks.json); status mapping matches the contract table byte-for-byte (passed→verified, failed→failed/check-failed, incomplete/not-applicable→not-verified + reason); limitations 5+1 with identical `source` anchors | Chain verified; **one gap found → #886** (supporting-scope prose, see P5b) | claims.json + recomputation (T2); publication_claims.zig:797-818 |
| P3a | Fixture reproduction — tooling | `python3 docs/audits/publication-proof-pack/check-parity.py` | `PARITY OK: all displayed facts match the JSON models` (exit 0); touches↔proof-pack binding digests verify byte-for-byte; node/edge counts match both README tables | Non-issue for internal consistency | T3 |
| P3b | Fixture reproduction — schemas | Ajv Draft 2020-12, all 6 examples vs published schemas | 3/3 touches examples valid; **3/3 proof-pack examples INVALID** (missing required `summary.artifacts.by_kind["static-file"]`) | **Confirmed defect → #887** | T3 |
| P3c | Fixture reproduction — real vs shown | minimal 1-page build (same inventory shape as `clean.json`) | real: 15 nodes / **28** edges (3 supporting: every committed artifact supports rendered-html, page supports rendered-search); fixture: 15 nodes / **26** edges (1 supporting; rendered-html supporting modeled empty) | **Confirmed defect → #887** (examples predate the shipped supporting scope) | T3c |
| P3d | Fixture README status lines | reading | both audit READMEs still say "implementation not yet shipped / Boris does not currently emit …" while the full five-file chain ships | folded into **#887** | T3d |
| P4a | Negative: plan that must fail | `static.dir == dist` and `static.dir == content` profiles | both `error: invalid publication profile: OutputConflict`, exit 2, no declaration on stdout — per profile contract ("may not nest with the target output or the content root") and plan contract (exit 2 class) | Non-issue | T4 |
| P4b | Negative: profile read failure | `boris plan --profile no-such-profile.json` | `error: unable to read publication profile: FileNotFound`, exit 3 | Non-issue (contracted exit-3 path) | T4 |
| P4c | Negative: nostr-bearing plan vs published schema | `boris plan --profile docs/contracts/fixtures/nostr-publication/profile.json` | exit 0 but declaration carries a root `"nostr"` key; Ajv: **invalid** against `publication-plan-1.schema.json` (`additionalProperties`) | **Confirmed defect → #885** | T4c |
| P5a | Drift sweep — schema vs runtime | Ajv on all real emitted evidence (default + static + draft builds) | artifacts/checks/claims/touches valid on every build; proof-pack valid for non-static targets but **INVALID for `--static-dir` targets** (`$defs.artifact_kind.enum` lacks `static-file`) | **Confirmed defect → #884** | T5 |
| P5b | Drift sweep — supporting scope vs prose | draft-page build + digest recomputation | emitted rendered-search `supporting_sha256` covers ALL committed html-pages (incl. `advertised:false` draft); ≠ the advertised-only set the contract prose defines; touches links `artifact:secret.html → check:rendered-search` | **Confirmed defect → #886** | T5b |
| P5c | Drift sweep — profile bounds vs contract | constants vs contract table | 262,144 / 16 / 4,096 / 1,024 / 32 / 256 / 64 / 1,024 all match `publication_profile.zig:18-25` | Non-issue | publication-profile.md §Strict JSON and bounds |
| P5d | Drift sweep — kind parse table | reading | `Kind.parse` carries the `static-file` entry twice (harmless; first-match wins) | **Confirmed defect (trivial) → #888** | artifact_inventory.zig:91-92 |
| P5e | Drift sweep — semantics row | static build artifacts.json | `static-file` records carry `semantics: static`; the contract row names only theme-owned `assets/` files | **Confirmed defect (docs precision) → #889** | T1 |
| W1 | Evidence chain byte bindings (default build) | sha256 recomputation over the four reports + HTML meta digest | touches bindings == actual file digests; claims binds exact artifacts/checks bytes; proof-pack four bindings agree; HTML-embedded `proof-pack-sha256` == sha256(proof-pack.json); `vcs_revision` present and nowhere upstream | Non-issue — split-pair detection works as contracted | T2 |
| W2 | Claims status mapping vs contract | code + fixture tests + real output | mapping table and 5+1 limitation split implemented exactly (`publication_claims.zig:797-818, 56-122`) | Non-issue | publication-claims.md §Fixed report shape |
| W3 | Overall presentation status derivation | code + real output (`verified` on clean builds) | closed vocabulary + ordered rule set implemented; `not-applicable` overall unreachable under the fixed registry, as the contract itself notes | Non-issue | publication-proof-pack.zig; publication-proof-pack.md §Summary |
| W4 | Plan prose vs schema — `static` projection key | reading + schema | `publication-plan.md` names sitemap/RSS/llms under `projections` without naming `static`; the published schema requires `static` and the emitter writes it | Non-issue (prose non-exhaustive; schema + profile contract own the shape) | publication-plan.md:97-99; schema `$defs/projections` |

## Probe transcripts

### T1 — P1: one static asset through inventory → plan → checks

```bash
$ cd /var/folders/.../opencode/p817-static
$ zig-out/bin/boris build --html-dir dist --html-layout layouts/main.html \
    --static-dir static --quiet ; echo "EXIT:$?"
EXIT:0
$ find dist -type f | sort
dist/.well-known/security.txt
dist/_boris/proof/artifacts.json
dist/_boris/proof/checks.json
dist/_boris/proof/claims.json
dist/_boris/proof/index.html
dist/_boris/proof/proof-pack.json
dist/_boris/proof/touches.json
dist/_boris/search/search-index.json
dist/guide.html
dist/index.html
dist/robots.txt
```

Inventory records (abridged to the deciding fields):

```text
.well-known/security.txt | static-file | static-files | semantics: static | advertised: null | required: true | bytes: 37
_boris/search/search-index.json | rendered-search | rendered-search | semantics: null | advertised: null | bytes: 459
guide.html | html-page | html-render | semantics: null | advertised: true | bytes: 369
index.html | html-page | html-render | semantics: null | advertised: true | bytes: 401
robots.txt | static-file | static-files | semantics: static | advertised: null | required: true | bytes: 24
```

Checks scopes and counts:

```text
artifact-integrity | passed | eligible 5, checked 5, findings 0
    subject statuses [committed], kinds [] ; supporting empty
rendered-html      | passed | eligible 2, checked 2, findings 0
    subject [committed]/[html-page] ; supporting [committed]/[]   (all kinds)
rendered-search    | passed | eligible 1, checked 1, findings 0
    subject [committed]/[rendered-search] ; supporting [committed]/[html-page]
```

Independent recomputation of the rendered-html supporting digest from raw
inventory records using the contract formula (`path NUL kind NUL bytes NUL
sha256 LF`, inventory order) matched the emitted `supporting_sha256` exactly.

Touch Atlas edges for the static files:

```text
artifact-subject-of-check : artifact:.well-known/security.txt -> check:artifact-integrity
artifact-subject-of-check : artifact:robots.txt               -> check:artifact-integrity
artifact-supports-check   : artifact:.well-known/security.txt -> check:rendered-html
artifact-supports-check   : artifact:robots.txt               -> check:rendered-html
```

Plan leg (profile `{"targets":[{"name":"public","output":"dist","public":true,
"static":{"dir":"static"}}]}`):

```bash
$ zig-out/bin/boris plan --profile boris.json ; echo "EXIT:$?"
{
  "format": "boris-publication-plan",
  "schema_version": 1,
  ...
  "targets": [
    {
      "name": "public",
      "output": "dist",
      "public": true,
      ...
      "projections": {
        "html": true,
        "sitemap": null,
        "rss": null,
        "llms": null,
        "static": {"dir": "static"}
      }
    }
  ],
  ...
}
EXIT:0
```

`publication-plan-1.schema.json` `$defs/projections` requires `html, sitemap,
rss, llms, static` — plan schema, plan output, and profile contract agree on
`static.dir`.

### T2 — P2 + W1: claims bindings and the full chain (default repo build)

```bash
$ zig-out/bin/boris --quiet ; echo "EXIT:$?"
EXIT:0        # dist/_boris/proof/{artifacts,checks,claims,touches,proof-pack}.json + index.html
```

Real chain facts (target `default`, 31 records: 26 html-page, 1 theme-asset,
3 content-asset, 1 rendered-search):

```text
checks: artifact-integrity 31/31 passed | rendered-html 26/26 passed | rendered-search 1/1 passed
claims: committed-artifacts-match-inventory      verified  check_id=artifact-integrity  limitations=5
        rendered-html-passed-declared-audit      verified  check_id=rendered-html       limitations=5
        rendered-search-matches-selected-html    verified  check_id=rendered-search     limitations=6
```

Mechanical re-verification (python, sha256 over exact bytes):

```text
touches.inputs.artifacts.sha256 == sha256(artifacts.json)  True
touches.inputs.checks.sha256    == sha256(checks.json)     True
touches.inputs.claims.sha256    == sha256(claims.json)     True
claims.publication_checks.sha256     == sha256(checks.json)     True
claims.artifact_inventory.sha256     == sha256(artifacts.json)  True
claim[2].evidence.checks_report_sha256 == sha256(checks.json)   True
proof-pack inputs (all four) agree byte-for-byte                  True
index.html <meta name="proof-pack-sha256" content="d6e799…5daed">
   == sha256(proof-pack.json)                                     True
proof-pack.vcs_revision = "e1e5da84"   (absent upstream)          True
touches: nodes 44, edges 165
```

Status mapping cross-check against the claims contract table: code
`publication_claims.zig:797-818` implements exactly passed→verified (no
reason), failed→failed/check-failed, incomplete→not-verified/check-incomplete,
not-applicable→not-verified/check-not-applicable; the six limitation rows
(5 shared + search-only `omitted-projections-not-certified`) and their
`source` anchors match the emitted bytes.

### T3 — P3: Touch Atlas / Proof Pack fixture reproduction

```bash
$ python3 docs/audits/publication-proof-pack/check-parity.py
checking clean.json ↔ index-clean.html
checking attention-required.json ↔ index-attention-required.html

PARITY OK: all displayed facts match the JSON models
```

Cross-example bindings (proof-pack `inputs.touches` vs Touch Atlas example
bytes): exact SHA-256 + byte-count match for all three pairs. Node/edge counts
match both README tables (15/26, 21/36, 15/25). Ajv Draft 2020-12:

```text
publication-touches-1.schema.json:   clean.json valid | failed-checks.json valid | search-not-applicable.json valid
publication-proof-pack-1.schema.json: clean.json INVALID | attention-required.json INVALID | search-not-applicable.json INVALID
  instancePath: '/summary/artifacts/by_kind'
  schemaPath:   '#/$defs/artifact_by_kind/required'
  missingProperty: 'static-file'
```

Real vs shown (P3c) — minimal build with the exact `clean.json` inventory
shape (1 page + rendered search, no static):

```bash
$ zig-out/bin/boris build --html-dir dist --html-layout layouts/main.html --quiet ; echo "EXIT:$?"
EXIT:0
```

```text
real touches.json: 15 nodes, 28 edges
  target-owns-artifact 2 | artifact-subject-of-check 4 | artifact-supports-check 3
  check-supports-claim 3 | claim-limited-by 16
fixture clean.json: 15 nodes, 26 edges
  target-owns-artifact 2 | artifact-subject-of-check 4 | artifact-supports-check 1
  check-supports-claim 3 | claim-limited-by 16
real proof-pack rendered-html.supporting_artifact_ids:
  [artifact:_boris/search/search-index.json, artifact:index.html]
fixture rendered-html.supporting_artifact_ids: []
```

The two extra supporting edges are the shipped rendered-html supporting scope
(every committed record) and the page→rendered-search edge; the fixtures model
a rendered-html supporting set of empty. Both README tables and the
"implementation not yet shipped" status lines carry the same pre-shipping
design. (`check-parity.py` and the digests confirm the examples are internally
consistent — the divergence is vs the shipped compiler, not within the
fixtures.)

### T4 — P4: negative probes

```bash
# static.dir nested with the target output (dist) / the content root
$ zig-out/bin/boris plan --profile boris-bad1.json ; echo "EXIT:$?"
error: invalid publication profile: OutputConflict
EXIT:2
$ zig-out/bin/boris plan --profile boris-bad2.json ; echo "EXIT:$?"
error: invalid publication profile: OutputConflict
EXIT:2
$ zig-out/bin/boris plan --profile no-such-profile.json ; echo "EXIT:$?"
error: unable to read publication profile: FileNotFound
EXIT:3
```

Nostr-bearing plan vs its published schema (P4c):

```bash
$ cd docs/contracts/fixtures/nostr-publication
$ zig-out/bin/boris plan --profile profile.json > plan-out.json ; echo "EXIT:$?"
EXIT:0
$ python3 -c "import json; print(list(json.load(open('plan-out.json')).keys()))"
['format', 'schema_version', 'input', 'input_format', 'site', 'publication',
 'targets', 'editions', 'nostr']
$ ajv validate --spec=draft2020 -s docs/contracts/schemas/publication-plan-1.schema.json -d plan-out.json
plan-out.json invalid
[
  {
    instancePath: '',
    schemaPath: '#/additionalProperties',
    keyword: 'additionalProperties',
    params: { additionalProperty: 'nostr' },
    message: 'must NOT have additional properties'
  }
]
```

`nostr-publication.md:142-145` *requires* this emission; `publication-plan.md`
and the published schema reject it → #885.

### T5 — P5: schema-vs-runtime sweep over real evidence

```text
Ajv Draft 2020-12, real emitted files:
default build:    artifacts ✓ | checks ✓ | claims ✓ | touches ✓ | proof-pack ✓
static build:     artifacts ✓ | checks ✓ | claims ✓ | touches ✓ | proof-pack INVALID
                    instancePath '/artifacts/0/kind'  schemaPath '#/$defs/artifact_kind/enum'
draft-bearing build: same as static (invalid only via static-file kind) — supporting-scope facts in T5b
```

Schema self-contradiction: the same file *requires*
`summary.artifacts.by_kind["static-file"]` while `$defs.artifact_kind.enum`
omits the kind. Root cause for the silent drift: `publication_checks.zig:1224`,
`publication_claims.zig:1181`, `publication_touches.zig:4823` each read the
real schema file and assert runtime-vs-schema parity, but
`publication_proof_pack.zig` has no such test → #884.

T5b (draft-bearing build, 3 pages, one `status: draft`):

```text
inventory: secret.html kind=html-page advertised=false committed
rendered-search emitted supporting_sha256
  == digest(ALL committed html-pages, incl. draft)        True
  == digest(committed ADVERTISED html-pages, per prose)   False
touches edges from artifact:secret.html:
  artifact-subject-of-check -> check:artifact-integrity
  artifact-subject-of-check -> check:rendered-html
  artifact-supports-check   -> check:rendered-html
  artifact-supports-check   -> check:rendered-search    <- checks.md:218-221 forbids
```

## Findings

| Issue | Severity | Class | Locus | Smallest remediation |
|---|---|---|---|---|
| [#884](https://github.com/drawmeanelephant/boris/issues/884) | medium | Confirmed — schema/runtime drift | `docs/contracts/schemas/publication-proof-pack-1.schema.json` `$defs.artifact_kind.enum`; emitter `src/publication_proof_pack.zig:622` | Add `static-file` to the enum; add the missing runtime-vs-schema parity test to `publication_proof_pack.zig` (the other three evidence modules have one) |
| [#885](https://github.com/drawmeanelephant/boris/issues/885) | medium | Confirmed — inter-contract contradiction + schema gap | `src/publication_plan.zig:99-132`, `src/publication_profile.zig:364,374` vs `publication-plan.md`, `publication-plan-1.schema.json`, `publication-profile.md:49-61,145-146` (against `nostr-publication.md:142-145`) | Declare the conditional closed `nostr` root object in the plan schema; document it in `publication-plan.md`; amend the profile root table + offline-boundary sentence |
| [#886](https://github.com/drawmeanelephant/boris/issues/886) | low | Confirmed — contract prose vs emitted scope | `publication-checks.md:217-221` vs `src/publication_checks.zig:645-647,673-675`; touches `src/publication_touches.zig:2706-2715` | Either narrow the prose to the declared selector vocabulary + state the #752 inspection rule separately (smallest), or add an eligibility dimension to scope selectors (schema-touching) |
| [#887](https://github.com/drawmeanelephant/boris/issues/887) | low | Confirmed — stale illustrative fixtures | `docs/audits/publication-touches/` + `docs/audits/publication-proof-pack/` (READMEs + 6 examples) | Refresh examples/READMEs to shipped behavior (status lines, `by_kind` `static-file`, supporting-edge counts); verify with check-parity.py + Ajv + real-build diff |
| [#888](https://github.com/drawmeanelephant/boris/issues/888) | trivial | Confirmed — redundant code | `src/artifact_inventory.zig:91-92` | Delete the duplicate `static-file` parse entry |
| [#889](https://github.com/drawmeanelephant/boris/issues/889) | low | Confirmed — contract precision | `publication-artifacts.md:90` vs `src/artifact_inventory.zig:699-703,756-760` | Extend the `semantics` row so `static` covers declared `static.dir` passthrough files |

Non-issues and verified-clean rows are in the falsification table (P1a-P1c,
P2-chain, P3a, P4a-P4b, P5c, W1-W4). No Likely findings remained after
falsification: every candidate either resolved to a cited code path, a
black-box repro, or a Non-issue.

## Close-out

- Probes run: 4 card probes (P1 static-file chain, P2 claim/check trace, P3
  fixture reproduction, P4 negative) + a drift sweep (P5); all four probes and
  the sweep have black-box command/output components pasted above.
- `zig build test` green before (exit 0) and after (exit 0) at `e1e5da84`,
  Zig 0.16.0.
- Findings: 6 Confirmed (#884-#889), 0 Likely, 0 Insufficient; the
  documented-limitation category was not needed (the supporting-scope prose in
  `publication-checks.md` is a contradiction, not a declared boundary — #886).
- This report is the only artifact of the card; authority was review-only.
