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
one-shot publish command, and a live smoke — is implemented and merged, with
one known external blocker: **no public PDS registers the Standard.site OAuth
permission set**, so the OAuth live-smoke cannot complete against any public
provider. The app-password credential path (the RFC's answer to that blocker)
is implemented and **pending review in PR #521**.

Everything compiles and the test suite is green on `afterparty`. There is no
known in-repo defect; the remaining work is external integration (a PDS that
grants the scope, or a live smoke against the app-password path) plus the
parked architectural question of whether Boris ever operates its own PDS.

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

## 3. What is pending review (PR #521, `feat/standard-site-app-password`)

Branch: `feat/standard-site-app-password` → PR
[drawmeanelephant/boris#521](https://github.com/drawmeanelephant/boris/pull/521).
Clean PR diff: 16 files, +1575/−73, all gates green locally.

1. **Opt-in app-password login** (`standard-site login --app-password
   (--did DID | --handle HANDLE)`) — the accepted RFC
   ([`atproto-app-password.md`](atproto-app-password.md), flipped to
   *Implemented*): a portable Bearer core (`src/atproto_password.zig`,
   `createSession`/`refreshSession` over `com.atproto.server.*`, JWT
   `exp`-`iat` lifetime parsing, DID revalidation, password zeroed after
   send), a `boris-app-password-v1` session document in the same 0600
   atomic-replace store, `SessionClient.fromBearerSession`, and an
   `AcquiredSession` tagged union so `publish`/`smoke` reuse either auth
   flavor. OAuth remains the default and is never silently downgraded.
2. **Terminal echo suppression** — while the app password is typed, termios
   `ECHO` is off for the read (restored via `defer` even on failure), and the
   read consumes exactly one line (`takeDelimiterExclusive('\n')`), which also
   fixes a pre-existing interactive hang (`allocRemaining` waited for EOF on a
   TTY). Piped secret files still read to EOF. Verified live over a pty:
   marker never echoed, ECHO restored, clean exit.

The RFC decision record: Boris is a **local CLI publisher**. v1 = existing
user PDS + app password + explicit CLI publish, with **zero Boris-operated
infrastructure**. A public/native OAuth client remains a v1.x/v2 option;
confidential OAuth/BFF infrastructure is explicitly out of scope unless a
product reason appears; **operating a PDS is not a Boris requirement**.

---

## 4. What remains to be done (the real list)

### 4.1 Live interop proof (the main external gap)

The smoke command is implemented and merge-tested, but it has never produced a
recorded pass artifact against a real PDS:

- **OAuth path:** blocked. No public PDS registers the Standard.site
  permission set (`site.standard.authFull`). bsky.social authorizes in the
  browser but returns a scope without the Standard.site permission; Boris
  fails closed with exit 6 (`compatibility`). This is recorded in
  [`atproto-live-smoke.md`](atproto-live-smoke.md) §"PDS OAuth scope support"
  and [`atproto-oauth.md`](atproto-oauth.md). The Standard.site author's own
  deployment (andromeda.social) is self-hosted; self-hosting a PDS is
  explicitly out of Boris scope for v1.
- **App-password path:** the RFC's answer — `createSession`/app passwords
  bypass OAuth scopes entirely, so a bsky.social smoke **can** complete
  through the app-password path once PR #521 lands. This is the fastest route
  to a real recorded artifact: log in with a test account's app password,
  run `standard-site smoke --did <test-DID>`, record the artifact.

**Suggested immediate work:** merge PR #521, then run the smoke against a
dedicated test account on bsky.social via app-password and commit the result
artifact as evidence.

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

- A live PDS rejection of an invalid app password surfaces as
  `UnexpectedRequest` (exit 3) rather than the friendlier `denial`
  classification — a pre-existing quirk of the live `createSession` path.
- The `publication_touches` OOM test has occasionally flaked with an OS KILL
  under memory pressure, then passed on re-run; unrelated to the
  Standard.site work, but worth a look if it bites CI.

### 4.4 GitHub bookkeeping

- PR #521 needs review + merge (CI is currently running; `mergeStateStatus`
  was `BLOCKED` → will flip to `CLEAN` when green). After merge, the
  app-password RFC should be linked from the closed #479/#478 issues or noted
  in #452.
- All nine issues from the original graph are closed; no re-open is
  warranted — the remaining work is external integration, not spec gaps.

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
./zig-out/bin/boris standard-site login  --app-password --did did:plc:...   # PR #521
./zig-out/bin/boris standard-site publish --profile <profile.json> --did did:plc:...
./zig-out/bin/boris standard-site smoke  --did did:plc:... [--surface-url ...] [--out ...]
```

Golden fixtures live under `docs/contracts/fixtures/publication-plan/` and the
C03/C04 conformance goldens under `docs/audits/publication-conformance/`.

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
| [`plain-text-projection.md`](plain-text-projection.md) | deterministic plain-text projection |
| [`publication-platforms.md`](publication-platforms.md) | publication-platform overview |
| [parent issue #452](https://github.com/drawmeanelephant/boris/issues/452) | the original spec; closed; this file is referenced from it |

---

## 8. Changelog for this document

| Date | Note |
|---|---|
| 2026-08-16 | Created. Records the merged #512 surface, the pending PR #521 (app-password + echo suppression), the live-PDS blocker, and the parked PDS/auth decision. |
