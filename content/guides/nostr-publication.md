---
title: Nostr NIP-23 Publication
parent: guides/overview
status: published
tags: [guides, nostr, nip-23, publication]
summary: Offline plan then sign, then publish. The secret and the network never mix. Not a verified target.
---

<p class="eyebrow">Nostr family</p>

# Nostr NIP-23 Publication {#nostr-publication}

Allowlisted pages can go out as NIP-23 long-form events (kind `30023`).
Three commands. One rule: **the secret and the network never mix**.

```text
boris nostr plan --profile PROFILE.json                       # offline
boris nostr sign --plan PLAN.json --key-stdin                 # offline
boris nostr publish --plan PLAN.json --bundle BUNDLE.json     # online
```

<Aside kind="info" id="not-the-default">

A bare `boris --quiet` never needs a key, a relay, or the network. A
failed Nostr run never invalidates a committed `dist/`. This is a CLI
family, **not** a verified target: no location adapter, no Proof Pack,
no live-smoke gate. See [[guides/publishing|Publishing Targets]].

</Aside>

## Pipeline {#pipeline}

| Command | Does | Key | Network | Writes |
| :--- | :--- | :--- | :--- | :--- |
| `nostr plan` | Allowlist + eligibility → plan | never | never | JSON on stdout |
| `nostr sign` | BIP-340 sign every article event | once, stdin | never | Bundle on stdout or `--out` |
| `nostr publish` | Deliver the exact signed events | never | the plan's relays | Report on stdout or `--out` |

Plan
: Reads the profile and the content tree. Exit `1` is an author problem.
  Exit `2` is an operator / profile problem.

Sign
: The only step that sees a key. 64 hex digits or a NIP-19 `nsec`. Never
  argv, profile, env, or log. Zeroed after use.

Publish
: The only step that opens a socket. Cross-checks the bundle against the
  plan first. Verdict lives in the report, not a collapsed "Published".

## Profile {#profile}

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

`pubkey` is 64 lowercase hex **or** a NIP-19 `npub1…`. The plan always
stores hex and also emits `author.npub`. `articles` is an exact entity-id
allowlist. Relays normalize to `wss://` and dedupe. Unknown keys fail in
the profile parser.

Each planned article carries `naddr` and `naddr_uri`. Paste `naddr` into a
Nostr client to open the long-form article. The address is
`(30023, pubkey, id)` and does not change when you edit the page.

## Sign {#sign}

```bash
boris nostr sign --plan plan.json --key-stdin --out bundle.json
```

<Aside kind="danger" id="key-hygiene">

Paste the key on stdin. Never put it on argv, in the profile, in the
environment, in git, or in evidence. `publish` must never see it.

</Aside>

- Event ids are the exact NIP-01 preimage. Signatures self-verify before
  the bundle is written.
- `created_at` defaults to now and must not precede `published_at`.
- Re-sign with `--prior PRIOR.json`. Unchanged articles reuse the prior
  event. A changed article needs a **strictly newer** `created_at` or
  the command fails with `ENOSTRTIME`.

## Publish {#publish}

```bash
boris nostr publish --plan plan.json --bundle bundle.json --out report.json
```

Production relays are `wss://` with hostname verification. `ws://` is
loopback-only. Timeouts retry the **identical** event bytes.

complete
: Every planned event was accepted.

partial
: Some relays or events failed; others did not.

failed
: Nothing usable landed.

incomplete
: The run did not finish cleanly (timeout, close, protocol).

A relay that demands NIP-42 AUTH is `auth-required/unsupported`. Other
relays are still attempted. Exit `0` means the run completed; read the
verdict in the report.

<Details summary="What this family will not do">

It will not delete remote events (no NIP-09). It will not fold into a
bare HTML build. It will not become GitHub Pages or Standard.site. A
removed local article does not retract anything on a relay.

</Details>

## Next

- [[guides/publishing|Publishing Targets]] — what is and is not verified
- [[reference/commands|Command Reference]] — flags
- [[reference/diagnostics|Diagnostics]] — `ENOSTR*` codes
- Contract: [`docs/contracts/nostr-publication.md`](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/nostr-publication.md)
