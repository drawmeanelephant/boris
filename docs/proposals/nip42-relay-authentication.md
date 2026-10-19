# NIP-42 relay authentication — signer/auth boundary design

**Status:** non-normative design document for reviewer decision (issue #1002,
first acceptance criterion). The approved boundary text and shipped behavior
are normative only in
[`docs/contracts/nostr-publication.md`](../contracts/nostr-publication.md)
("Approved NIP-42 boundary (phase 1, #1002)") and
[`publication-profile.md`](../contracts/publication-profile.md); this document
records the design rationale, consolidates the boundary for review, and lists
the questions that need a reviewer decision. It amends no contract and
authorizes no code change by itself. The scoped macOS implementation (merged
via PRs #1016 and #1017) already follows the boundary described here; where
this document and the contract disagree, the contract is authority and this
document is wrong.

## Problem and constraints

Some configured relays demand NIP-42 client authentication before accepting an
`EVENT`. The v1 publish slice reports that demand honestly as `auth-required`
(unsupported) and moves on — the #493 decision, which stands. Issue #1002
asks for an opt-in phase-2 capability under fixed constraints:

- Authentication is explicit and opt-in; nothing changes for profiles that do
  not opt in.
- `publish` never receives or persists the long-lived author secret. The
  ephemeral kind-`22242` challenge response still has to be signed, so the
  crux is *where that signature happens*.
- Challenge handling is relay-scoped, bounded, and fail-closed.
- Per-relay reporting distinguishes auth-required, malformed challenges,
  timeouts, and authentication rejection; other relays continue where safe.
- The test suite stays offline and secret-free.

## Protocol basis and revision check

Governing facts re-read from the official NIP-42 and NIP-01 texts:

- NIP-42 is `draft`, `optional`, `relay`. The relay sends
  `["AUTH", <challenge-string>]`; the client answers
  `["AUTH", <signed-event>]`; the relay answers with an `OK`.
- The challenge is an **untrusted string**, not a signed relay statement.
  There is no challenge signature or timestamp to verify. The enforceable
  checks are transport peer authentication, exact connection association,
  local lifetime limits, and verification of *our* response event.
- The response is kind `22242` (ephemeral per NIP-01), with `relay` and
  `challenge` tags and a current `created_at`. An auth `OK` names the **auth
  event id**, not the article id. `auth-required:` means authentication is
  needed; `restricted:` means the authenticated identity is not authorized.

**Revision status.** The contract pins `nostr-protocol/nips` at
`656cecc7c0a815b6a2b218d3b5d6f078b3f4dbab` (2026-08-08). That pin is **no
longer repository HEAD**: upstream `master` is
`37db639582d857e12468dcccd99b2c7f1d657da9` (2026-10-17). Re-reading NIP-42
and NIP-01 at HEAD on 2026-10-18 shows two changes since the pin:

1. `42.md` gained a NIP-67 "`auth` hint in `EOSE`" subsection — it governs
   `REQ`/query flows, not `EVENT` publication, and is out of scope here.
2. `01.md` gained filter-semantics clarifications (empty filter lists match
   nothing; `limit: 0` returns no stored events) — query semantics, unrelated
   to event ids, signatures, or the AUTH exchange.

No governing fact this design relies on changed between the pin and HEAD.
Whether to record a deliberate pin bump to `37db639…` is left as an open
question below — moving the pin is a revision bump with a re-read, never an
implicit follow of `master`.

## The signer/auth boundary

The boundary keeps the existing invariant — *the secret and the network never
meet* — by splitting the auth flow across **two processes with a narrow IPC
contract**:

```text
operator ──key──▶ nostr sign --auth-session        (supervisor: has key, no sockets)
                        │ anonymous pipes, "boris-nostr-auth-ipc" v1
                        ▼
                  nostr publish --auth-pipes 3,4   (child: has sockets, no key)
                        │ WebSocket
                        ▼
                      relay
```

- **The supervisor** is a separate, explicit mode of `nostr sign`
  (`--auth-session`). It holds the author key in memory for one invocation,
  opens no sockets, and does one thing on request: construct and sign the
  kind-`22242` event itself, after independently validating every policy and
  correlation field. It never signs an article, an arbitrary digest, or
  another kind; the publisher cannot supply a kind, timestamp, tags, content,
  event id, or preimage.
- **The publisher child** is the existing keyless publish slice spawned by the
  supervisor from the resolved same executable (no shell, `PATH`, or helper).
  It owns all relay I/O, forwards only the opaque relay-bound challenge and
  public correlation fields, and independently re-verifies the returned event
  (id preimage, BIP-340 signature, identity, relay binding, freshness) before
  sending `AUTH`.
- **Nothing secret crosses the pipe**: no key, derived secret, keypair, nonce
  seed, secp256k1 context, or signing auxiliary randomness — including at
  process creation. Spawn/exec/`ready` complete *before* the supervisor reads
  the key once from its own stdin under the existing 128-byte `--key-stdin`
  policy; the child gets `/dev/null` stdin, two pipe endpoints, report stdout,
  diagnostic stderr, and nothing else (`CLOEXEC_DEFAULT`, empty environment).
- **Where the secret may live:** supervisor memory only, for the session's
  lifetime. Core dumps are disabled before key ingestion; input/key/aux
  buffers are zeroed best-effort and the context destroyed on every handled
  exit. There is no key file, daemon, named pipe, listening socket,
  environment credential, or signer plugin.
- **Honest limits:** the supervisor cannot prove a challenge string arrived on
  a particular connection (there is no signed relay challenge); a compromised
  publisher could request a bounded number of auth proofs (at most two per
  opted-in relay) but nothing else; a compromised supervisor exposes its key.
  This is a process/API separation, **not** an OS sandbox or hardware key
  store, and platforms that cannot meet the custody rules must refuse session
  mode (today only macOS implements it, via `posix_spawn` + explicit
  descriptor allowlist; Linux refuses rather than approximating).

Module ownership on `main`: `src/nostr_auth.zig` (public policy, correlation,
challenge/generation/replay limits, narrow construction and independent
verification), `src/nostr_auth_ipc.zig` (anonymous-pipe framing, per-frame
non-renewing deadlines), `src/nostr_auth_session.zig` (custody supervisor),
the existing `src/nostr_publish.zig` + RFC-6455 transport (all relay work).
Message schema:
[`schemas/nostr-auth-ipc-1.schema.json`](../contracts/schemas/nostr-auth-ipc-1.schema.json)
— closed objects, all fields required, 32,768-byte frame bound, UTF-8 strict,
nesting ≤ 8, versioned handshake.

## Opt-in profile and CLI surface

One closed profile object under `nostr`, additive to the schema-1 grammar:

```json
"auth": { "mode": "nip42", "relays": ["wss://auth-relay.example.org"] }
```

Exactly `mode` and `relays`; `relays` is a non-empty normalized
sorted-subset of `nostr.relays`; URLs ≤ 1,024 UTF-8 bytes; the existing
32-relay cap still bounds the session. Unknown keys/modes, duplicates, wrong
types, and non-subsets fail preflight. The expected auth identity is
`nostr.pubkey` — there is no separate credential declaration. An opted-in
profile emits **schema-2** plans/bundles/reports (`delivery.auth` carries the
static subset) so a schema-1 consumer must refuse rather than silently skip
authentication; old strict profile parsers already reject `auth` as an
unknown key.

CLI: `boris nostr sign --auth-session --plan PLAN --bundle BUNDLE --key-stdin
[--report-out PATH]` requires the already-signed bundle, rejects `--prior` /
`--created-at` / bundle `--out`, and forwards the child report. The child
runs `nostr publish` with the private `--auth-pipes 3,4` flag (fixed
descriptor pair; any other spelling refused). A direct `nostr publish` on an
opt-in plan **without** a session refuses before opening sockets (exit 2).
With `auth` absent, every byte and behavior of the v1 pipeline is unchanged:
no `"auth": null`, no supervisor, no challenge wait; relays outside the
subset use the existing unauthenticated path, and an unexpected auth demand
there remains `auth-required`, never automatic consent.

## Fail-closed challenge gate

Per opted-in relay, proactive-only, on the same live connection (summary of
the contract's nine-step gate):

1. Verify WebSocket upgrade + `wss` CA/hostname **before** any signing
   request; bind the response to the configured normalized URL exactly
   (scheme, port, path). `ws://` stays loopback-test-only.
2. Accept only a two-element `["AUTH", string]`: valid UTF-8, 1–4,096 decoded
   bytes, no C0 controls/DEL, no trimming or normalization; malformed
   frames/JSON fail the relay.
3. Track `(run, connection, relay, generation, challenge)` transiently; a
   repeated decoded challenge on that relay this run fails as `replay`. No
   durable replay database, no cross-run claim.
4. First challenge within `timeout_ms`; then one **non-renewing** auth
   deadline of `min(3*timeout_ms, 60_000)` covering sign, verify, AUTH write,
   and matching `OK`. NOTICE/Ping/fragments/replacement never extend it.
5. **One** distinct replacement permitted before the first article (generation
   2 under the same deadline); a third challenge, repeat, or post-article
   replacement fails closed. Retired `OK`s are discarded exactly once.
6. Supervisor constructs exactly `{pubkey: expected author, created_at: now,
   kind: 22242, tags: [["relay", url], ["challenge", exact]], content: ""}`,
   computes id, signs with fresh CSPRNG aux bytes, self-verifies.
7. Publisher independently re-checks correlation, active
   challenge/generation/connection, deadline, pubkey, exact shape, and
   `created_at` within **60 s** of wall clock; recomputes the NIP-01 preimage
   id and verifies the signature. Any mismatch sends neither AUTH nor EVENT.
8. Send the verified event once as `["AUTH", event]` on that connection only;
   accept only an exact four-element `["OK", auth_id, bool, string]` matching
   that id. `true` opens the article gate; `false` is rejection.
9. Only then send the exact already-signed NIP-23 event, unchanged. Article
   timeout retries reuse the authenticated connection; `retries` never
   retries authentication.

A new `AUTH` after article delivery terminates that relay's session rather
than starting another signing round. A relay that only challenges *after* a
denied `EVENT` is a documented incompatibility: this slice sends no
speculative article and reports `challenge-timeout`.

## Per-relay outcome taxonomy

Schema-2 reports keep article outcomes separate from a per-relay `auth`
object. Non-opted-in relays report `not-requested`.

| Final auth status | Meaning | Article outcome before any article |
|---|---|---|
| `not-requested` | Relay outside the subset | Existing v1 outcome |
| `authenticated` | Matching positive auth `OK`, connection intact | Determined by article results only |
| `rejected` | Matching negative auth `OK` | `auth-required` for the prefix, else `rejected` |
| `timeout` | Challenge, signer, AUTH-write, or auth-OK deadline missed | `timeout` |
| `closed` | Relay closed before authentication completed | `closed` |
| `protocol-error` | Malformed/oversized/replayed/stale/mismatched challenge, response, or `OK`; replacement-policy violation | `error` |
| `signer-error` | Key/signing/session refused or signer channel unavailable | `error` |

Reason codes are a closed vocabulary (`challenge-timeout`, `signer-timeout`,
`auth-write-timeout`, `auth-ok-timeout`, `malformed`, `oversized`, `replay`,
`stale`, `relay-mismatch`, `identity-mismatch`, `event-id-mismatch`,
`signature-invalid`, `unexpected-ok`, `replacement-limit`,
`replacement-after-event`, `auth-required`, `restricted`, `relay-rejected`,
`relay-closed`, `session-timeout`, `signer-refused`, `signer-unavailable`,
`session-invalid`, `not-opted-in`) — standardized prefixes, never arbitrary
relay text. `ENOSTRRELAY` carries relay URL, auth phase, and fixed
reason/remediation; no challenge, key input, auth event bytes, IPC payload,
or raw signer error is ever interpolated. Auth success alone never counts as
article acceptance; run classification stays
`complete`/`partial`/`failed`/`incomplete`, with auth timeouts able to yield
`incomplete` even when unsent articles would otherwise hide them. Temporal
auth evidence lives only in the publish report — no challenge, timestamp, or
outcome enters a plan or bundle.

## Offline, secret-free test plan

All coverage runs under `zig build test` / `zig build test-nostr` against
hostile loopback recording relays with injected clocks and fixed aux bytes —
no public relay, no real credential, no live-smoke gate. Public disposable
BIP-340 test scalars in memory are fine; an operator key in a fixture never
is. The matrix in `src/nostr_publish_matrix_test.zig` plus focused
verifier/policy/IPC/process tests assert, at minimum: proactive multi-article
success with verified AUTH tags/id/signature and byte-identical articles;
negative `OK` prefixes (`auth-required:`, `restricted:`) with zero article
writes; auth-success + article-rejection kept separate; malformed, oversized,
fragmented, and multibyte challenge/`OK` inputs at exact-limit and limit+1;
signer substitution (wrong identity, URL, challenge, kind, tags, correlation,
id, signature); freshness skew and replay across generation/connection/run;
one replacement with late replies vs. third/post-article replacement;
silence, NOTICE/Ping floods, and blocked-signer deadlines; operation-triggered
challenge = `challenge-timeout`, no fallback; Close/cancellation/signer death
with bounded teardown and no fabricated report; the non-renewing 600,000 ms
session ceiling; launch/custody proofs (exec/`ready` before key read, no
inherited key-bearing descriptors — Darwin `FIONREAD` asserts the unread
stdin queue); mixed authenticated/unauthenticated relays and every verdict
combination; identical-byte article retries without auth re-send; schema-1
goldens unchanged; and output hygiene (no test key, raw challenge, auth
signature/event, IPC transcript, or malicious relay text in outputs).
Recording relays assert **absence** of `EVENT` before the gate, not merely a
failure report.

## Open questions for reviewer decision

1. **Pin bump.** Keep `656cecc7…` or deliberately bump the documentation pin
   to `37db639…` (verified HEAD as of 2026-10-18)? The post-pin diffs are
   query-side only; either way the bump must be recorded as a revision change
   in the contract, not silently followed.
2. **Operation-triggered challenges.** Proactive-only is the approved first
   slice. Relays that challenge only after a denied `EVENT` currently get
   `challenge-timeout`. Supporting them requires a reviewed consent change
   (the initial article crosses the wire before auth). Acceptable as a
   documented limitation for #1002 close-out?
3. **Re-auth after article delivery.** A post-article `AUTH` currently ends
   the relay session rather than re-authenticating. Is that the right
   close-out position, or should reconnect/re-auth be a follow-up card?
4. **Platform coverage.** Custody launch is macOS-only; Linux is
   cross-compiled, refuses session mode, and Windows is unimplemented. Is
   macOS-only sufficient to close #1002, with per-platform cards for the
   rest?
5. **Identity and signer scope.** First slice authenticates only the planned
   author via the local supervisor — no multi-identity auth, no remote
   signer/NIP-46, no throwaway-key delegation (none exists at this pin).
   Confirm these remain explicitly out of scope.
6. **Issue close-out.** Given the boundary is documented here and in the
   contract and the scoped implementation landed via PRs #1016/#1017 with
   macOS evidence, does this document satisfy #1002's first acceptance
   criterion, and what remains to close the issue itself?
