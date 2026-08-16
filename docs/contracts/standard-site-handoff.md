# Standard.site / AT Protocol publication — implementation handoff

**As of:** 2026-08-16 · **Integration line:** `afterparty`
**Purpose:** a single document that records what is implemented, what is merged,
what is pending review, and what genuinely remains to be done for the
Standard.site / AT Protocol publication target. Written for a fresh set of
eyes (human or agent) to pick up the thread without re-deriving the history.

The normative behavior of every item below lives in the sibling contract
documents; this file is a status map, not a contract. When in doubt, the
contract wins.

---

## 1. Executive summary

The full offline Standard.site publication chain is implemented, tested, and
merged into `afterparty` (PR #512). The online half — OAuth sessions, a
one-shot publish command, live smoke, and the opt-in app-password path — is
also merged (PR #521, `fc29928`). A **recorded passing live smoke** against
bsky.social via app-password is in
[`fixtures/standard-site-live-smoke/`](fixtures/standard-site-live-smoke/README.md).

The remaining external blocker is OAuth-only: **no public PDS registers the
Standard.site OAuth permission set**, so the OAuth live-smoke still cannot
complete against bsky.social (exit 6). The parked architectural question is
whether Boris ever operates its own PDS.

---

## 2. What is merged into `afterparty` (PR #512, squash-merged `5ab06bd`)

The parent issue #452 and all eight children (#473–#481) are **closed** with
"Implemented and merged via #512." The merged surface:

| Capability | Contract | Where in the tree |
|---|---|---|
| Offline deterministic projection + plan (`standard-site plan`) | [`standard-site.md`](standard-site.md), [`publication-plan-1.schema.json`](schemas/publication-plan-1.schema.json) | `src/standard_site.zig` |
| Plan carries the full `textContent` + digest | [`standard-site.md`](standard-site.md) | `src/standard_site.zig` |
| Full record payload dump (`standard-site records`) | [`standard-site.md`](standard-site.md) | `src/standard_site.zig` |
| Offline verify of emitted head links + well-known (`standard-site verify`) | [`standard-site.md`](standard-site.md) | `src/standard_site_emit.zig`, `src/main.zig` |
| Verification surfaces (publication + document) | [`standard-site-reconciliation.md`](standard-site-reconciliation.md) | `src/standard_site_emit.zig` |
| Typed DPoP-authenticated XRPC record client | [`atproto-oauth.md`](atproto-oauth.md) | `src/atproto_xrpc.zig`, `src/atproto_oauth.zig`, `src/atproto_authorization.zig` |
| Reconciliation + publish evidence | [`standard-site-reconciliation.md`](standard-site-reconciliation.md) | `src/standard_site_reconcile.zig`, `src/standard_site_publish.zig` |
| One-shot local publish (`standard-site publish`) | [`standard-site.md`](standard-site.md) | `src/standard_site_publish.zig`, `src/main.zig` |
| Persistent OAuth sessions (`login`/`logout`/`sessions`) | [`atproto-sessions.md`](atproto-sessions.md) | `src/atproto_session_store.zig`, `src/atproto_session_std.zig` |
| Bounded live smoke (`standard-site smoke`, opt-in) | [`atproto-live-smoke.md`](atproto-live-smoke.md) | `src/standard_site_smoke.zig` |
| Deterministic plain-text projection | [`plain-text-projection.md`](plain-text-projection.md) | `src/plain_text.zig` (rendering path) |

All of these are covered by `zig build test`, the per-module test steps, the
release gate, and the C03/C04 publication-conformance goldens.

---

## 3. What landed after the first handoff (PR #521 + live-smoke follow-up)

PR [drawmeanelephant/boris#521](https://github.com/drawmeanelephant/boris/pull/521)
merged to `afterparty` as `fc29928` on 2026-08-16. CI was red on help-text
goldens (`--handle` / `--app-password`); those C03/C04 fixtures were
regoldened and the new run was green on Ubuntu and macOS before merge.

1. **Opt-in app-password login** (`standard-site login --app-password
   (--did DID | --handle HANDLE)`) — the accepted RFC
   ([`atproto-app-password.md`](atproto-app-password.md), *Implemented*):
   portable Bearer core, `boris-app-password-v1` session document, Bearer
   XRPC, `AcquiredSession` tagged union. OAuth remains the default and is
   never silently downgraded.
2. **Terminal echo suppression** — termios `ECHO` off for the interactive
   read; one line consumed; piped secrets still read to EOF.
3. **Live-smoke follow-up** (this pickup) — three live-path defects that
   unit mocks never saw:
   - `StdTransport` only admitted OAuth form+DPoP POSTs, so
     `createSession` and Bearer/DPoP XRPC were rejected as
     `UnexpectedRequest` before a socket opened.
   - `deleteRecord` required `commit` to be a string; a live PDS returns
     lexicon `commitMeta` `{ cid, rev }`, so cleanup was marked failed
     even when the delete succeeded.
   - Live `getRecord` injects `$type`; exact-value readback failed. Readback
     now requires every intended field and tolerates extra remote keys.

The RFC decision record is unchanged: Boris is a **local CLI publisher**.
v1 = existing user PDS + app password + explicit CLI publish, with **zero
Boris-operated infrastructure**. Operating a PDS is not a Boris requirement.

---

## 4. What remains to be done (the real list)

### 4.1 Live interop proof

The app-password live smoke is **done**. Recorded artifact:

[`fixtures/standard-site-live-smoke/bsky.social.json`](fixtures/standard-site-live-smoke/bsky.social.json)

| Field | Value |
|---|---|
| Date | 2026-08-16 |
| Handle | `tbuddy23.bsky.social` |
| DID | `did:plc:fqf5y5yyddraj7pywme4al2i` |
| PDS | `https://morel.us-east.host.bsky.network` |
| Namespace | `boris-live-20260816b` |
| Verdict | `passed` (discovery, authorization, write, readback, cleanup) |
| Indexer | `lagged` (non-normative; AppView had not ingested before cleanup) |

- **OAuth path:** still blocked. No public PDS registers
  `site.standard.authFull`. bsky.social authorizes in the browser but
  returns a scope without the Standard.site permission; Boris fails closed
  with exit 6. Unchanged; recorded in
  [`atproto-live-smoke.md`](atproto-live-smoke.md) and
  [`atproto-oauth.md`](atproto-oauth.md).

### 4.2 PDS / auth architecture decision (parked by the user)

There is no dedicated test PDS. The working decision: "no dedicated PDS for
now; do local stuff and make the tool more featureful until the PDS question
is worked out better." The open sub-questions, for whenever someone picks them
up:

- Self-host a PDS for a dedicated Standard.site test identity (or use
  andromeda.social if accessible) to unlock the **OAuth** live smoke.
- Whether Boris's app-password path should become the documented primary
  credential for CLI publishing (the RFC says opt-in; OAuth stays primary).

### 4.3 Small known quirks (non-blocking, documented)

- The earlier note that an invalid app password surfaces as
  `UnexpectedRequest` was a misdiagnosis: the native adapter was rejecting
  the JSON `createSession` shape before the request left the machine. After
  the transport fix, a genuine PDS rejection classifies as `denial` /
  `AuthenticationFailed` (exit 4).
- The `publication_touches` OOM test has occasionally flaked with an OS KILL
  under memory pressure, then passed on re-run; unrelated to the
  Standard.site work, but worth a look if it bites CI.

### 4.4 GitHub bookkeeping

- PR #521 is merged. The app-password RFC and the recorded live-smoke
  artifact are noted on closed #452 (and should be mirrored on #479/#481
  if a later pass wants the child issues to point at the follow-up).
- All nine issues from the original graph remain closed; the remaining work
  is the parked PDS/OAuth-scope question, not a spec gap.

---

## 5. Architecture map (where things live)

```text
offline (credential-free, deterministic, in CI)
  src/standard_site.zig          projection, rkeys, eligibility, plan, records
  src/standard_site_emit.zig     verification surfaces + offline verify core
  src/main.zig                   runStandardSitePlan/Records/Verify/Publish/Login/...
  src/cli.zig                    standard-site family parsing + validation

identity + discovery
  src/atproto_identity.zig       DID resolution (DID document, PDS discovery)
  src/atproto_handle.zig         handle -> DID (DNS/HTTPS)
  src/atproto_dns.zig/.std.zig   DNS plumbing (portable + std)

transport + XRPC
  src/atproto_transport.zig      transport interface (injected, no host caps)
  src/atproto_transport_std.zig  std/http implementation
  src/atproto_xrpc.zig           typed XRPC record client (DPoP + Bearer variants)
  src/atproto_oauth.zig          DPoP, PAR, nonce tracking, JWT parsing

auth + sessions
  src/atproto_authorization.zig  authorized-session type + refresh
  src/atproto_interactive_std.zig  one-shot browser OAuth flow
  src/atproto_browser_std.zig / src/atproto_loopback_std.zig  browser/loopback
  src/atproto_password.zig       Bearer createSession/refreshSession core (PR #521)
  src/atproto_session_store.zig  0600 atomic-replace store (OAuth + app-password docs)
  src/atproto_session_std.zig    Sessions lifecycle (acquire/store/logout)

publish + reconcile + smoke
  src/standard_site_publish.zig  one-shot publish orchestration
  src/standard_site_reconcile.zig  remote readback + evidence
  src/standard_site_smoke.zig    bounded live interop gate

build + tests
  build.zig                      per-module test steps (test-standard-site,
                                 test-standard-site-emit, test-atproto-xrpc,
                                 test-atproto-password, ...), wasm32-freestanding
                                 gate for the network/auth cores
  src/emitter_discipline_test.zig  audit that auth clients are not emitters
```

Portability note: the transport/auth cores (`atproto_xrpc`, `atproto_oauth`,
`atproto_password`) compile for `wasm32-freestanding` (no host capabilities,
injected transport); the std/network/browser/session layers are host-side.
`std.posix.termios` echo control is comptime-guarded to macOS/Linux.

---

## 6. Verification cheat sheet

```bash
zig build                          # build
zig build test                     # full suite (exit 0 = pass)
zig build test-standard-site       # projection/plan/records
zig build test-standard-site-emit  # surfaces + verify
zig build test-atproto-xrpc        # XRPC client + freestanding gate
zig build test-atproto-password    # app-password core (PR #521)
zig build test-atproto-session-store / test-atproto-session-std
./scripts/release-gate.sh          # release gate
zig fmt --check src/ build.zig
git diff --check

# offline commands (no network, deterministic)
./zig-out/bin/boris standard-site plan    --profile <profile.json>
./zig-out/bin/boris standard-site records --profile <profile.json>
./zig-out/bin/boris standard-site verify  --profile <profile.json> --dist dist

# live (manual, opt-in)
./zig-out/bin/boris standard-site login  --did did:plc:...            # OAuth
./zig-out/bin/boris standard-site login  --app-password --did did:plc:...   # or --handle
./zig-out/bin/boris standard-site publish --profile <profile.json> --did did:plc:...
./zig-out/bin/boris standard-site smoke  --did did:plc:... [--surface-url ...] [--out ...]
```

Golden fixtures live under `docs/contracts/fixtures/publication-plan/` and the
C03/C04 conformance goldens under `docs/audits/publication-conformance/`.
The recorded live-smoke artifact is
[`docs/contracts/fixtures/standard-site-live-smoke/`](fixtures/standard-site-live-smoke/README.md).

---

## 7. Key documents

| Document | Role |
|---|---|
| [`standard-site.md`](standard-site.md) | Standard.site target: records, rkeys, plan, publish |
| [`standard-site-reconciliation.md`](standard-site-reconciliation.md) | verify surfaces + evidence |
| [`atproto-oauth.md`](atproto-oauth.md) | OAuth/DPoP client contract (incl. scope limitation) |
| [`atproto-sessions.md`](atproto-sessions.md) | persistent session document + lifecycle |
| [`atproto-app-password.md`](atproto-app-password.md) | **RFC (Implemented)** opt-in app-password path |
| [`atproto-live-smoke.md`](atproto-live-smoke.md) | live smoke contract + PDS scope-support survey |
| [`fixtures/standard-site-live-smoke/`](fixtures/standard-site-live-smoke/README.md) | recorded passing bsky.social app-password smoke |
| [`plain-text-projection.md`](plain-text-projection.md) | deterministic plain-text projection |
| [`publication-platforms.md`](publication-platforms.md) | publication-platform overview |
| [parent issue #452](https://github.com/drawmeanelephant/boris/issues/452) | the original spec; closed; this file is referenced from it |

---

## 8. Changelog for this document

| Date | Note |
|---|---|
| 2026-08-16 | Created. Records the merged #512 surface, the pending PR #521 (app-password + echo suppression), the live-PDS blocker, and the parked PDS/auth decision. |
| 2026-08-16 | PR #521 merged. Recorded a passing bsky.social app-password live smoke. Fixed native-transport Bearer/JSON admission, live `commitMeta` delete parse, and `$type`-tolerant readback. OAuth scope gap and parked PDS question remain. |
