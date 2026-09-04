# Code-health audit report — publication targets (GitHub Pages, Standard.site, AT Protocol, Nostr)

**Card:** #818 (milestone [Code health pass](https://github.com/drawmeanelephant/boris/milestone/2), epic #807, tranche 2 of #807's sweep)
**Authority:** review only — no product-code changes on this card. Findings
filed individually: #892, #893, #894, #895, #896, #897, #898 (Confirmed);
#899, #900, #901, #902 (coverage/doc-drift Confirmed + one Likely).
**Commit audited:** `main` @ `e1e5da84` (branch `audit/818-publication-targets`)
**Zig:** 0.16.0 (homebrew), macOS arm64 (darwin)
**Gate:** `zig build test` green before probes and re-run green after (exit 0 both).

## Setup

- Fresh branch `audit/818-publication-targets` from `origin/main` tip
  `e1e5da84`; `git status --short` clean except the report itself.
- `zig build test` → exit 0 before any probe work; re-run exit 0 after
  (148 source modules classified, emitter-discipline ok).
- Black-box probes: `zig build` binary `zig-out/bin/boris` against a
  `boris init`-scaffolded tree in `/var/folders/.../T/opencode/probe-818`
  (`site/`, a second tree `site2/`, a fabricated `session-root/`); exit
  codes and full output below.
- Contracts read first (normative): `docs/contracts/publication-platforms.md`
  (registry), `docs/github-pages.md` (the card's `github-pages.md` — it
  lives at `docs/` root, not `docs/contracts/`), `standard-site.md`,
  `nostr-publication.md`, `atproto-app-password.md`; per-pointer
  `github-pages-deployment-evidence.md`, `standard-site-reconciliation.md`,
  `rss-2.0.md` (eligibility cross-reference).
- Locus files read: `src/github_pages.zig` (full), `src/publication_profile.zig`
  (`parsePublication`/`parseNostr`/tests), `src/standard_site.zig`,
  `src/standard_site_emit.zig`, `src/standard_site_publish.zig`,
  `src/standard_site_reconcile.zig`, `src/standard_site_smoke.zig`,
  `src/nostr.zig`, `src/nostr_plan.zig`, `src/nostr_emit.zig`,
  `src/nostr_sign.zig`, `src/nostr_publish.zig`, `src/nostr_keys.zig`,
  `src/ws_client.zig`, `src/atproto_password.zig`,
  `src/atproto_session_store.zig`, plus the packaging script
  `scripts/prepare-github-pages-artifact.sh`. Drift checked both
  directions: two structured contract-vs-code sweeps over the
  standard-site and nostr families; **every filed lead re-verified by
  direct code read or black-box run** (three agent leads were disproven
  and downgraded — S4, S7, and the "missing fixture" note on #900).
- Key material for probes: the NIP-19 test vector `nsec`
  (`src/nostr.zig:1072-1082`, upstream NIPs pin) and its BIP-340
  x-only pubkey (derived off-repo by point multiplication; the secret
  was an upstream published test vector and is present in this repo's
  own tests).

## Falsification table

| # | Probe | Commands (abridged) | Result | Classification | Evidence |
|---|-------|---------------------|--------|----------------|----------|
| P1a | Registry: `publication.target = "nostr"` rejected | `boris plan --profile nostr-target.json` | exit 2, `error: invalid publication profile: InvalidPublication`; no plan bytes | Non-issue (registry rule holds) | `docs/contracts/publication-platforms.md:89,108-129`; `src/publication_profile.zig:490-534` (fallback :533) |
| P1b | `github-pages` parses | `boris plan --profile pages-target.json` | exit 0; `boris-publication-plan` emitted with `"target": "github-pages"` | Non-issue | `src/publication_profile.zig:494-504`; `src/github_pages.zig:122-163` |
| P1c | `standard-site` parses | `boris plan --profile standard-site.json` | exit 0; plan with `"target": "standard-site"` | Non-issue | `src/publication_profile.zig:505-532` |
| P2a | Nostr plan carries public key only | `boris nostr plan --profile nostr.json` | plan has `author.expected_pubkey` + `author.npub`; grep `nsec|privkey|private.key|secret` + the nsec vector + its hex over plan bytes and diagnostics → 0 matches; `created_at/event_id/signature` are explicit nulls | Non-issue (nulls fixture-aligned) | `src/nostr_plan.zig:400-405,470-474`; fixture `expected/plan.json:48-50` carries identical nulls |
| P2b | Signed bundle carries no key | `printf 'nsec1vl02…\n' \| boris nostr sign --plan … --key-stdin --out …` | exit 0 bundle; grep `nsec|<vector hex>|privkey` over bundle → 0 matches; `signature_verified: true` | Non-issue | `src/nostr_sign.zig:492-575` (bundle schema, no key field); golden `expected/signed-bundle.json` |
| P2c | Standard.site plan carries no credential | `boris standard-site plan --profile standard-site.json --out …` | grep `accessJwt|access_token|bearer|nsec` over plan bytes → 0 matches | Non-issue | `src/standard_site.zig:433-502` payload fields; contract `standard-site.md:216-218` |
| P2d | Sessions listing redacts tokens | fabricated `boris-app-password-v1` doc with marker tokens `…probe818.secret…`; `boris standard-site sessions --session-root <abs>` | exit 0; one row `did flavor pds_origin` only; grep markers + `access_token|refresh_token|bearer|jwt` over stdout+stderr → 0 matches | Non-issue | `src/main.zig:1017-1018`; `src/atproto_session_store.zig:329-353,410-429` (`peekPublicFields` reads format+pds only) |
| P2e | App-password empty stdin fails closed pre-network | `printf '' \| boris standard-site login --app-password --did …` | disclosure line first, then `password cannot be empty; nothing was stored`, exit 2 | Non-issue | `docs/contracts/atproto-app-password.md` (Secret input; disclosure); `src/main.zig:830-855,922-973` |
| P3a | Pages custom domain + non-empty path rejected | `boris plan --profile pages-custom-domain-path.json` (`docs.example.com` + `/boris`) | exit 2, `InvalidPublication` | Non-issue | `src/github_pages.zig:148-149` (`CustomDomainBasePath`); `docs/github-pages.md:41-44` |
| P3b | Pages artifact excludes `_boris/proof`, evidence retained | `bash scripts/prepare-github-pages-artifact.sh dist <dest> dist/_boris/proof/artifacts.json default <summary>` | exit 0; 5 files copied; `find dest -path "*_boris/proof*"` → 0; `dist/_boris/proof/` retained (6 files); summary `proof_paths_excluded: true` | Non-issue | script :83-85 (reject), :115-116 (index.html), :141 |
| P3c | Poisoned inventory with a `_boris/proof` record fails | inventory + `_boris/proof/claims.json` committed row | exit 1, `unsafe or private artifact path: _boris/proof/claims.json` | Non-issue (defense-in-depth beyond current inventories) | script :82-86 |
| P4a | Nostr failed-publish classification + per-relay evidence | `boris nostr publish --plan … --bundle … --out report.json` against `ws://127.0.0.1:9` (closed; `nc -z` confirms) | exit 0 with report; `classification: "failed"`; relay `{url, outcome: "error", attempts: 1, events: [{result: "error", message: "ConnectFailed"}]}`; stderr `ENOSTRRELAY` diagnostic | Non-issue | `src/nostr_publish.zig:385-401` (classify), :426-435 (connect failure), :607-629 (ENOSTRRELAY); `src/main.zig:1970-1998` (report + exit 0); contract table `nostr-publication.md:543-559` |
| S1 | Omitted page status planned as document | `articles-omitstatus.md` (no status) → `boris standard-site plan` | document record emitted for the omitted-status page | **Confirmed defect → #892** | `src/standard_site.zig:377-385` vs `docs/contracts/standard-site.md:71,80` |
| S2 | Mid-glob include silently exact-matches | `publication.include = ["articles/*/mid"]` → plan | page excluded `filtered`; pattern matched nothing | **Likely defect → #899** | `src/standard_site.zig:402-409` vs `docs/contracts/standard-site.md:45` |
| S3 | Exclusion token spelling | plan exclusions for a no-date page | `"reason": "missing-date"` (contract: `missing_date`) | **Confirmed defect → #896** | `src/standard_site.zig:1022` vs `docs/contracts/standard-site.md:80` |
| S4 | Malformed `published_at` "fails the whole plan" (sweep lead) | `published_at: 2026-13-45T00:00:00Z` → `boris standard-site plan` | upstream graph validation rejects first: `EFRONTMATTER … published_at must be exactly YYYY-MM-DDTHH:MM:SSZ` — the projection-level error path is unreachable | Non-issue (lead downgraded — hard fail-closed upstream) | `src/main.zig` graph validation; `src/standard_site.zig:337-371,635` |
| S5 | Disabled `nostr` section requires keys | profile `{"nostr": {"enabled": false}}` → `boris plan` | exit 2 `MissingField` | **Confirmed defect → #894** | `src/publication_profile.zig:383-406` vs `docs/contracts/nostr-publication.md:169-171` |
| S6 | Profile `name`/`description` parse bound | `publication.name = "N"*2000 / "N"*30000` → `boris plan` | exit 2 `InvalidSite` / `StringTooLong` (contract: ≤5000 / ≤30000) | **Confirmed defect → #895** | `src/publication_profile.zig:25,553-557` vs `docs/contracts/standard-site.md:42-43` |
| S7 | `nostr plan --out` "silently ignored" (sweep lead) | `boris nostr plan --profile … --out missing.json` | exit 2 usage; stdout empty; file not created — the flag is refused, not ignored | Non-issue (lead disproven) | `src/cli.zig` parse gate; `docs/contracts/nostr-publication.md:103-106` |
| S8 | Secret key case acceptance | uppercase 64-hex of the test vector via `--key-stdin` | exit 0 bundle written | **Confirmed defect → #897** | `src/nostr.zig:637-648` vs `docs/contracts/nostr-publication.md:408-409` |
| S9 | Fail-closed Markdown validation fires | hard-wrapped paragraph in allowlisted article → `boris nostr plan` | exit 1 `ENOSTRMARKDOWN: … hard-wrapped-paragraph [join the paragraph onto one line…]` | Non-issue (positive) | `src/render.zig:193-225`; contract :262 |
| W1 | Plan `created_at/id/sig` nulls vs "absent from the plan" | fixture compare | emitted nulls + `created_at_policy` byte-match `expected/plan.json:48-50`; "absent" = value-absence | Non-issue | `src/nostr_plan.zig:470-474`; `docs/contracts/nostr-publication.md:55-56` |
| W2 | `research_date: "2026-08-14"` vs contract revision date 2026-08-08 | fixture + `nostr_plan.zig:57` | research date ≠ revision date; the field's value is not normatively fixed by the contract | Non-issue | `docs/contracts/nostr-publication.md:77,472` |
| W3 | Contract-internal: "the classification is the last field" (:558) vs its own example (:570-581) | code compare | implementation follows the schema example (classification precedes `relays`) | Non-issue (wording nit; schema example wins) | `src/nostr_publish.zig:734-736` |
| W4 | Empty/oversized stdin key exit class | read | both exit 2 (usage) — operator-input class, not `ENOSTRSIGN` | Non-issue | `src/main.zig:1850-1864` |
| W5 | Registry validated by "isValidTargetName" (contract wording) | code + history | registry is closed equality (`parsePublication`); `isValidTargetName` governs the HTML `targets` name field only (since `104c07e8`) | **Confirmed defect (doc drift) → #898** | `docs/contracts/publication-platforms.md:110-113` vs `src/publication_profile.zig:494,505,533,583`; `src/target.zig:214` |
| W6 | `ExitCode.session` (9) untested | test read + search | "ExitCode contract surface" asserts 0–8 only | **Confirmed defect (coverage) → #901** | `src/main.zig:3112-3122` |
| W7 | Standard-site branch of `parsePublication` untested | test read | test block :799-1009 covers github-pages + nostr only | **Confirmed defect (coverage) → #900** | `src/publication_profile.zig:505-531` |
| W8 | `_boris/proof/standard-site.owner` undocumented | read + search | compiler-owned marker (`emitted\n`/`limited\n`) staged on every production render; named by no contract | **Confirmed defect (doc drift) → #902** | `src/standard_site_emit.zig:33,205-224` |
| W9 | Secret-handling sweep (evidence, human summaries, smoke, store) | code + tests | `failure` fields carry `@errorName` only; evidence/human summary built from the evidence struct; smoke result secret-free; store `0700`/`0600` + secure-zero + `peekPublicFields` | Non-issue (positive — no leak path found) | `standard_site_publish.zig:924` (test "evidence and human summary never leak session secrets"), `standard_site_reconcile.zig:1371`, `standard_site_smoke.zig:1143`, `atproto_session_store.zig:687,727` |
| W10 | BIP-340 dependency pin | `src/nostr_keys.zig:10-14` + `build.zig.zon:16-19` | v0.8.0, tag `18f07c42…`, commit `6e2c8bc4…`, archive sha256 `eb52b0e9…d17c8bb` — all four match the contract | Non-issue (positive) | `docs/contracts/nostr-publication.md:416-422` |
| W11 | ws_client transport conformance | code + matrix tests | ws:// loopback-only (:522), HostName resolution for named hosts + literal path (#545) (:295-317), TLS hostname verification + system CA (:595-630), 0-byte TLS read tolerance (#552) (:705-746), exact handshake validation (:751-796), client masks + masked-server-frame refusal (:403-409,436-437), control/oversize rules (:445-471), 64 KiB fragmentation (:58,804-825), deadlines on every read/write (:262-282), Ping→Pong/Close (:856-874) | Non-issue (positive) | `nostr_publish_matrix_test.zig` (28 loopback/TLS scenarios incl. "mixed relays classify partial" :783, "hostname mismatch fails closed" :943) |
| W12 | Empty entity id → error, not digest fallback | code | `error.InvalidPage` on empty id; digest fallback only for >512-byte reversible form; empty ids cannot occur (identity grammar) | Non-issue (unreachable input; hardening) | `src/standard_site.zig:285-312,567` |
| W13 | `preferences` omitted when `show_in_discover=false` | code | optional-field omission; contract example shows the key populated | Non-issue (ambiguous example) | `src/standard_site.zig:443-449` |
| W14 | Prune enumerates only exclusion-derived rkeys | code | orphan enumeration limited to locally-derivable rkeys; digest-fallback rkeys are irreversible so full enumeration is impossible | Insufficient evidence (contract wording ambiguous; no defect provable) | `src/standard_site_reconcile.zig:313-326` vs `docs/contracts/standard-site.md:46` |
| W15 | Retry byte-identity asserted by count only | matrix test | matrix asserts 2 EVENT frames, not byte-equality; identity is structural (`renderEventMessage` deterministic over verified fields) and byte-exactness is pinned by the write-fuzz test | Non-issue | `nostr_publish_matrix_test.zig:758-781,1107-1178` |
| W16 | Verification surfaces (head slot, well-known sideband, verify exit 8) | code + compile tests | `{{head}}` closed slot with empty-slot rule, `EVERIFICATIONHEAD` warning, sideband for base-path sites, deterministic report, verify zero-writes exit 8 | Non-issue (positive) | `standard_site_emit.zig:113-127,180-203,233-275,286-334`; `compile_standard_site_test.zig:67,206` |

## Probe transcripts (full output)

### P1 — target registry

```text
$ boris plan --profile nostr-target.json      # publication.target = "nostr"
error: invalid publication profile: InvalidPublication
exit=2
$ boris plan --profile pages-target.json      # publication.target = "github-pages"
{
  "format": "boris-publication-plan",
  "schema_version": 1,
  "input": "content",
  "input_format": "markdown",
  "site": { "url": null, "title": "Probe 818", "description": null },
  "publication": {
    "target": "github-pages",
    ...
exit=0
$ boris plan --profile standard-site.json     # publication.target = "standard-site"
...
    "target": "standard-site",
exit=0
```

### P2 — secret leakage

```text
$ boris nostr plan --profile nostr.json > nostr-plan.json 2> nostr-plan.err
exit=0 ; tail nostr-plan.err: "boris: ignite validating graph"
$ rg -in "nsec|privkey|private.key|secret" nostr-plan.json nostr-plan.err   # 0 lines
$ rg -c "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa" nostr-plan.json
0 — secret absent
$ rg '"expected_pubkey"|"npub"' nostr-plan.json
    "expected_pubkey": "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e",
    "npub": "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
$ printf 'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5\n' \
  | boris nostr sign --plan nostr-plan.json --key-stdin --out nostr-bundle.json
ok: wrote signed-event bundle to nostr-bundle.json     # exit=0
$ rg -in "nsec|67dea2ed…|privkey|private" nostr-bundle.json    # 0 lines
$ boris standard-site plan --profile standard-site.json --out ss-plan.json
$ rg -in "probe818.secret|accessJwt|access_token|bearer|nsec" ss-plan.json    # 0 lines
```

Sessions listing (fabricated `boris-app-password-v1` document whose
tokens embed the marker `probe818.secret`):

```text
$ boris standard-site sessions --session-root "$PWD/session-root"
did:plc:ewvi7nxzyoun6zhxrhs64oiz app-password https://pds.probe818.invalid
standard-site: 1 stored session
exit=0
$ rg -in "probe818.secret|dummy-access|dummy-refresh|access_token|refresh_token|bearer|jwt" sessions.out sessions.err
# 0 matches (grep exit 1)
```

Empty app-password stdin:

```text
$ printf '' | boris standard-site login --app-password --did did:plc:ewvi7nxzyoun6zhxrhs64oiz
standard-site: --app-password grants broad account write access to did:plc:ewvi7nxzyoun6zhxrhs64oiz on https://enoki.us-east.host.bsky.network (not just the Standard.site scope). Revoke it under App Passwords in your provider's account settings.
error: standard-site login --app-password: password cannot be empty; nothing was stored
exit=2
```

### P3 — Pages location model + artifact boundary

```text
$ boris plan --profile pages-custom-domain-path.json   # base_url=…/docs.example.com/boris
error: invalid publication profile: InvalidPublication
exit=2
$ bash scripts/prepare-github-pages-artifact.sh dist ../pages-artifact dist/_boris/proof/artifacts.json default ../pages-copy-summary.json
github-pages-artifact: verified 5 files (34467 bytes) for default
exit=0
$ find ../pages-artifact -type f | sort
../pages-artifact/_boris/search/search-index.json
../pages-artifact/assets/css/boris.css
../pages-artifact/guides/getting-started.html
../pages-artifact/guides/publishing.html
../pages-artifact/index.html
$ find ../pages-artifact -path "*_boris/proof*" | wc -l          # 0
$ ls dist/_boris/proof/   # evidence retained: artifacts.json checks.json claims.json index.html proof-pack.json touches.json
$ cat ../pages-copy-summary.json
{
  "format": "boris-github-pages-artifact-verification",
  "schema_version": 1,
  "target": "default",
  "files": 5, "bytes": 34467, "max_bytes": 1073741824,
  "inventory_sha256": "4a9b84596df7eb9a12c45088bb3280bbdec03000f637694770491b77a060cc86",
  "public_manifest_sha256": "cab8c745dc667e33c7a0babcbf7f03746d65d7fc8fb4284ab680de1bb1e4fc1e",
  "index_path": "index.html",
  "proof_paths_excluded": true,
  "symlinks_rejected": true,
  "hard_links_rejected": true
}
# poisoned inventory (adds a committed `_boris/proof/claims.json` row):
$ bash scripts/prepare-github-pages-artifact.sh dist ../pages-artifact2 ../poisoned-inventory.json default ../poison-summary.json
github-pages-artifact: unsafe or private artifact path: _boris/proof/claims.json
exit=1
```

### P4 — Nostr publish error path (offline relay)

```text
$ nc -z 127.0.0.1 9 ; echo nc=$?        # nc=1 (port closed)
$ boris nostr publish --plan nostr-plan.json --bundle nostr-bundle.json --out nostr-publish-report.json 2> nostr-publish.err
error: ENOSTRRELAY: ws://127.0.0.1:9: ws://127.0.0.1:9: connect or handshake failed (ConnectFailed) [check the relay's policy and connectivity, then re-run]
ok: wrote publish report (failed) to nostr-publish-report.json
exit=0
$ cat nostr-publish-report.json
{
    "format": "boris-nostr-publish-report",
    "schema_version": 1,
    "plan":    { "format": "boris-nostr-publication-plan", "schema_version": 1,
                 "digest": "d02d074f9611e6b496eddf7423f304c0fb36b62d27781bc2e3f50a3631310958" },
    "bundle":  { "format": "boris-nostr-signed-bundle", "schema_version": 1,
                 "digest": "92eaa6265a5a94834ad9321fac5480b9678b5aaca649fece4c633dd1a3f4545c" },
    "signer": { "pubkey": "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e" },
    "classification": "failed",
    "relays": [
        {
            "url": "ws://127.0.0.1:9",
            "outcome": "error",
            "attempts": 1,
            "events": [
                { "entity_id": "", "event_id": "", "result": "error", "message": "ConnectFailed" }
            ]
        }
    ]
}
```

(`partial`/`complete`/`incomplete` are pinned by the loopback matrix —
`nostr_publish_matrix_test.zig` "mixed relays classify partial and keep
per-relay evidence" :783, "an honest relay accepts the event (complete)"
:623, "a silent relay hits the deadline and the run is incomplete" :684 —
and by the dated checked-in live-smoke fixture `fixtures/nostr-live-smoke/`.)

### S-probes (findings + downgraded leads)

```text
# S1 — omitted status planned (contract says excluded):
$ boris standard-site plan --profile standard-site.json --out omit-plan.json   # site2 tree
exit=0
$ rg '"entity_id"|"reason"|"title"' omit-plan.json | head -6
"entity_id": "articles/omitstatus",
"title": "Omit Status",            # ← planned document, no status frontmatter
"entity_id": "index",
"reason": "missing-date",          # ← S3 token spelling, hyphen

# S5 — disabled nostr section:
$ boris plan --profile nostr-disabled.json    # {"nostr": {"enabled": false}}
error: invalid publication profile: MissingField
exit=2

# S6 — parse bound vs contract table:
$ boris plan --profile big-ss-name.json       # publication.name = "N"*2000
error: invalid publication profile: InvalidSite
exit=2
$ boris plan --profile big-ss-name-30k.json   # publication.name = "N"*30000
error: invalid publication profile: StringTooLong
exit=2

# S4 — malformed date rejected upstream (lead downgraded):
$ boris standard-site plan --profile standard-site.json --out out.json   # published_at: 2026-13-45T00:00:00Z
error: EFRONTMATTER: articles-nodate.md:5:1: published_at must be exactly YYYY-MM-DDTHH:MM:SSZ with a valid UTC calendar date [Fix the frontmatter or encoding for this file]
exit=1

# S7 — nostr plan --out is refused, not ignored:
$ boris nostr plan --profile nostr.json --out ../should-not-exist.json > plan-c-stdout.json
usage: boris <command> [options] (run boris --help for the full option list)
exit=2 ; stdout bytes=0 ; ../should-not-exist.json: absent

# S8 — uppercase hex key accepted:
$ printf '67DEA2ED018072D675F5415ECFAED7D2597555E202D85B3D65EA4E58D2D92FFA\n' \
  | boris nostr sign --plan nostr-plan.json --key-stdin --out bundle-upper.json
ok: wrote signed-event bundle to bundle-upper.json    # exit=0

# S9 — fail-closed Markdown validation (incidental positive):
$ boris nostr plan --profile nostr.json    # article with a source-wrapped paragraph
error: ENOSTRMARKDOWN: articles/nostr-probe.md: articles/nostr-probe: publication-safe Markdown line 4: hard-wrapped-paragraph [join the paragraph onto one line; NIP-23 forbids hard-wrapped prose]
exit=1

# S2 — mid-glob include:
$ boris standard-site plan --profile midglob.json   # publication.include = ["articles/*/mid"]
exit=0
"entity_id": "articles/omitstatus",
"reason": "filtered",                               # ← silently dropped (exact-match semantics)
```

## Findings

1. **#892 Confirmed defect (medium):** Standard.site plans an off-contract
   record set — omitted page status is eligible (`standard_site.zig:377-385`,
   RSS-mirror comment; black-box: omitted-status page becomes a
   `site.standard.document`), contradicting `standard-site.md:71`
   ("published or archived"); the `unsupported` exclusion reason
   (`standard-site.md:80`, `standard_site.zig:210,593-599`) is unreachable
   dead vocabulary.
2. **#893 Confirmed defect (medium):** publication-safe Markdown ships
   relative link hrefs — the fail-closed "unresolved relative URL" row
   (`nostr-publication.md:263-264`) is enforced only for the four
   Boris-mediated classes (`nostr_plan.zig:232-260`); ordinary authored
   relative links pass (`doclink.zig:289-297`; `render.zig:193-225`
   inspects only html/soft-break; black-box: `](vendor/spec.html)`
   published in `content`).
3. **#894 Confirmed defect (low):** a disabled `nostr` profile section
   requires `pubkey`/`articles`/`relays` the contract conditions on
   `enabled` (`publication_profile.zig:383-406` vs
   `nostr-publication.md:169-171`; black-box: `{"enabled": false}` →
   exit 2 `MissingField`).
4. **#895 Confirmed defect (low):** Standard.site profile
   `name`/`description` parse bound is 1024 bytes
   (`publication_profile.zig:25,553-557`) vs the contract's ≤5000/≤30000
   (`standard-site.md:42-43`); black-box: 2000-byte name → `InvalidSite`,
   30000 → `StringTooLong`; the payload-side 5000/30000 limits are
   unreachable.
5. **#896 Confirmed defect (low):** Standard.site exclusion wire token
   renders `missing-date` (`standard_site.zig:1022`) vs the contract's
   `missing_date` (`standard-site.md:80`); no fixture pins the spelling
   (checked-in expected plan has an empty exclusions array).
6. **#897 Confirmed defect (low):** nostr secret key accepts either-case
   64-hex (`nostr.zig:637-648`) vs the contract's "64 lowercase hex
   digits" (`nostr-publication.md:408-409`); black-box uppercase sign
   succeeds. Accepts-more, no security impact.
7. **#898 Confirmed defect (low, doc drift):** `publication-platforms.md:110-113`
   attributes registry validation to `isValidTargetName`; the registry is
   closed name equality (`publication_profile.zig:494,505,533`);
   `isValidTargetName` governs the HTML `targets` name field
   (:583, since `104c07e8`).
8. **#899 Likely defect (low):** Standard.site include/exclude filters
   silently give mid-glob patterns exact-match semantics
   (`standard_site.zig:402-409` vs `standard-site.md:45` "glob patterns");
   wrong record set is visible as `filtered` rows in the reviewed plan.
9. **#900 Confirmed defect (low, coverage):** no parser-level test
   exercises the standard-site branch of `parsePublication`
   (`publication_profile.zig:505-531`; test block :799-1009 covers
   github-pages + nostr only).
10. **#901 Confirmed defect (low, coverage):** `ExitCode.session` (9)
    numeric value is asserted nowhere ("ExitCode contract surface",
    `main.zig:3112-3122`, stops at 8).
11. **#902 Confirmed defect (low, doc drift):** `_boris/proof/standard-site.owner`
    (`standard_site_emit.zig:33,205-224`) is an undocumented
    compiler-owned proof artifact; `standard-site.md` names only the
    verification report and the well-known sideband.

## Non-issue observations recorded for the record (no action)

- The registry rule holds end to end: `nostr` is rejected with exit 2,
  `github-pages`/`standard-site` parse and emit plans byte-identically to
  their fixtures (P1).
- Secret discipline held everywhere probed: the nostr plan carries
  `expected_pubkey`/`npub` only (nulls are the fixture-aligned
  value-absence form, W1); the bundle carries no key; the Standard.site
  plan, the sessions listing, and the publish evidence/summary/smoke
  surfaces carry no credential (P2, W9); the app-password path fails
  closed on empty input with the disclosure line first (P2e).
- Pages location model exact: custom domain + non-empty path rejected
  (`CustomDomainBasePath`), `base_url == origin + base_path` cross-checked
  (P3a); packaging rules exact: committed-records-only, byte+SHA verified,
  `index.html` required, symlinks/hard-links rejected, `_boris/proof`
  excluded with the evidence retained in the workspace tree (P3b/P3c).
- Nostr error paths honest: report written + exit 0 with the
  `failed` verdict carried by the report; per-relay `error`/`ConnectFailed`
  evidence matches the closed vocabulary; `ENOSTRRELAY` publish-only
  (P4, W16). `partial`/`complete`/`incomplete` pinned by the loopback
  matrix and the dated live-smoke fixture.
- Sweep leads downgraded on verification: the "malformed date fails the
  whole plan" path is unreachable (upstream `EFRONTMATTER`, S4); `nostr
  plan --out` is refused, not silently ignored (S7); the standard-site
  profile fixture exists at `docs/contracts/fixtures/publication-plan/standard-site/`
  (swept correctly into #900's evidence).
- Transport conformance positive across the checked points (#545 host
  resolution, #552 0-byte TLS read, masked-server-frame refusal, exact
  handshake validation, deadlines, 64 KiB fragmentation) — W11.
- secp256k1 pin matches the contract on all four values — W10.
- `research_date` (2026-08-14) is a research date, not the NIPs revision
  date (2026-08-08); the contract does not normatively fix the value — W2.
- Remaining wording/ambiguity nits without a provable defect side: the
  "classification is the last field" sentence vs its own example (W3);
  `preferences` omission at `show_in_discover=false` (W13); prune's
  enumeration reachability (W14); empty/oversized stdin key classified
  usage (W4); empty-entity-id digest fallback unreachable (W12); retry
  byte-identity pinned structurally + by the write-fuzz test (W15).

## Exit checklist

- [x] 5 contracts read before the locus files (registry, github-pages,
      standard-site, nostr-publication, atproto-app-password)
- [x] Locus files read (`github_pages`, `standard_site*`, `atproto_*`
      secret-handling surface, `nostr*`, `ws_client`, Pages packaging
      script); drift checked both directions
- [x] ≥3 falsification probes, ≥2 black-box: satisfied — 4 card probes
      (P1–P4), all black-box binary runs with pasted output, plus 9
      supplementary black-box probes (S1–S9)
- [x] Falsification table with file:line + test-name citations per row
- [x] Every material observation classified exactly once (Confirmed /
      Likely / Insufficient evidence / Non-issue)
- [x] Findings filed individually: #892–#902 (each with severity, class,
      locus file:line, repro, impact, smallest remediation, verification)
- [x] `zig build test` green before and after probe work (exit 0 both runs)
- [x] Report PR targeting `main` (this PR)
- [x] Close-out comment posted on #818 with the mandated template
