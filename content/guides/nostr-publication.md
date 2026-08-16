---
title: Nostr NIP-23 Publication
parent: guides/overview
status: published
tags: [guides, nostr, nip-23, publication]
---

# Nostr NIP-23 Publication (plan → sign → publish)

Boris can publish allowlisted documentation pages to the Nostr network as
NIP-23 long-form-content events (kind `30023`). The pipeline is three
commands, and its central rule is that **the secret and the network never
mix**: signing is the only step that reads a key, and publishing is the only
step that contacts a relay.

```text
boris nostr plan --profile PROFILE.json                       # offline
boris nostr sign --plan PLAN.json --key-stdin                 # offline
boris nostr publish --plan PLAN.json --bundle BUNDLE.json     # online
```

<Aside kind="info">

A bare `boris build` never needs a key, a relay, or the network, and a
failed Nostr operation never invalidates a committed website. The Nostr
surface is one projection among several — the same validated content graph
also feeds HTML, RAG, Context, `llms.txt`, and RSS.

</Aside>

## The pipeline at a glance

| Command | What it does | Key | Network | Writes by default |
|---|---|---|---|---|
| `boris nostr plan` | Selects the profile's `nostr` allowlist and emits the publication plan | never | never | Plan JSON on stdout |
| `boris nostr sign` | Signs every article's NIP-01 event id with BIP-340 and writes a signed-event bundle | once, from stdin | never | Bundle JSON on stdout or `--out PATH` |
| `boris nostr publish` | Delivers the exact signed events to the plan's relays and writes a per-relay report | never | the plan's relays | Report JSON on stdout or `--out PATH` |

## Step 1 — plan: `boris nostr plan --profile PATH`

The `nostr` section of the publication profile declares what will be
published and where:

```json
"nostr": {
  "enabled": true,
  "pubkey": "1f2e3d4c5b6a7988796a5b4c3d2e1f00112233445566778899aabbccddeeff00",
  "articles": ["guides/intro", "notes/why-boris"],
  "relays": ["wss://relay.example.org", "wss://relay.example.net"],
  "timeout_ms": 5000,
  "retries": 2
}
```

`pubkey` is the expected author public key (NIP-01 hex, not `npub`);
`articles` is the exact entity-id allowlist; `relays` are normalized to
`wss://` and deduplicated. The key set is closed — unknown keys, wrong
types, and invalid values are rejected by the strict profile parser before
any content is read.

`plan` reads only the profile and the content tree, validates eligibility
and publication-safe Markdown, and writes the plan document to stdout. Exit
`1` means an author must change a page; exit `2` means an operator must
change the profile.

## Step 2 — sign: `boris nostr sign --plan PLAN.json --key-stdin`

```bash
# Bundle to stdout:
boris nostr sign --plan plan.json --key-stdin < secret.key

# Bundle to a file:
boris nostr sign --plan plan.json --key-stdin --out bundle.json < secret.key
```

- The secret key is **64 hex digits or a NIP-19 `nsec`**, read once from
  stdin. It is never accepted from argv, a profile, an environment variable,
  or a log, and it is zeroed best-effort after use.
- Every article's event id is computed from the exact NIP-01 preimage
  (`[0, pubkey, created_at, kind, tags, content]`) and signed with a BIP-340
  Schnorr signature (bitcoin-core/secp256k1, pinned and verified). The
  signature is verified before any bundle is written.
- `created_at` defaults to the current Unix time and must not precede the
  article's `published_at`. Pass `--created-at N` only for test/recovery.
- Re-signing an updated plan? Pass `--prior PRIOR.json`. An unchanged
  article reuses its exact prior signed event; a changed article requires
  a **strictly newer** `created_at` (NIP-01 tie-break), and the command
  fails deterministically rather than risk losing the replacement.

## Step 3 — publish: `boris nostr publish --plan PLAN.json --bundle BUNDLE.json`

```bash
boris nostr publish --plan plan.json --bundle bundle.json --out report.json
```

- Nothing is sent before the bundle is cross-verified against the plan:
  the bundle's plan digest, the expected pubkey, every event id, and every
  signature.
- The exact signed events are sent over WebSocket to each relay, and the
  client waits, bounded, for a matching `OK`. Production relays are
  `wss://` with TLS hostname verification; `ws://` is accepted only for
  loopback/test relays.
- Every relay produces per-event evidence, and the run reaches an honest
  verdict: `complete`, `partial`, `failed`, or `incomplete` — never a
  collapsed "Published" boolean. A relay that demands NIP-42 authentication
  is reported honestly as `auth-required/unsupported`; the other relays are
  still attempted. Timeouts retry the identical event bytes.
- The report goes to `--out` or stdout. The command returns exit `0` on any
  completed run — the verdict lives in the report, not the exit code.

## Key hygiene and safety

- The offline commands (`plan`, `sign`) never open a socket; `publish` never
  sees a key.
- The key never enters site output, plans, profiles, logs, or evidence.
- A failed publish never touches the committed website, and nothing is ever
  deleted automatically (removing a local article performs no NIP-09
  action).

## Next steps

- [[reference/commands|Command Reference]] — the full CLI surface and exit codes
- [[reference/diagnostics|Diagnostics & Troubleshooting]] — `ENOSTR*` codes
- [[guides/rag-export|AI & Machine Outputs]] — the other machine projections
- The normative contract lives at
  [`docs/contracts/nostr-publication.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/nostr-publication.md)
