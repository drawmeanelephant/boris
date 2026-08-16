# Nostr first-tester live-smoke evidence

Recorded result of one disposable-identity `boris nostr plan` / `sign` /
`publish` run against public relays. This is observational evidence, not a
CI gate, not a Proof Pack claim, and not a `boris nostr smoke` command.

| Field | Value |
|---|---|
| Artifact | [`report.json`](report.json) |
| Date | 2026-08-16T17:11:16Z |
| Compiler | `boris/0.8.1` |
| Identity | disposable; secret shredded after sign |
| Pubkey | `b6e744290c2e00b4d5cc96dfae0b61e52707a800f39e0d8d6e326a3e9b67d049` |
| npub | `npub1kmn5g2gv9cqtf4wvjm06uzmpu5ns02qq7w0qmrtwxf4raxm86pyshrnecq` |
| Event id | `0ef0b1001237376f9152098b1605dea991f34f874b6c7fc6de5d52d037467dfa` |
| naddr | `naddr1qqzhxmt0ddjsyg9kuazzjrpwqz6dtnykm7hqkc09yur6sq8nncxc6m3jdglfke7sfypsgqqqw4rszrthwden5te0dehhxtnvdakqzrmhwden5te0dehhxarj9ekk7mgpz3mhxue69uhhyetvv9ujuerpd46hxtnfduq3vamnwvaz7tmjv4kxz7fwwpexjmtpdshxuet53hetrm` |
| Classification | `partial` |

Accepted: `wss://nos.lol`, `wss://nostr.mom`, `wss://relay.primal.net`.
`wss://relay.damus.io` failed the WebSocket upgrade (`BadStatus`) on two
attempts. `partial` is the honest verdict: three relays accepted the same
event, one did not.

The JSON is the product `boris-nostr-publish-report`. It contains no secret
key, no `nsec`, and no signing material beyond the public event id.

An earlier disposable run after #562 classified `complete` on the same four
relays (event `175f263d7fe8c952ff34fc0a6c3daced54613ac08f48462fd5d5afe4c4af4db4`).
That run is a PR note, not this fixture. Relays can refuse tomorrow.

## How to re-run

Manual and opt-in. Ordinary `zig build test` must stay offline and
secret-free. Do not use a personal key. Do not put a key on argv, in the
profile, in the environment, or in git. `publish` never sees the secret.

The operator steps are the first-person try on
[#454](https://github.com/drawmeanelephant/boris/issues/454) and the
[Nostr publication guide](../../../../content/guides/nostr-publication.md).

```text
boris nostr plan --profile PROFILE.json > plan.json
tr -d '\n' < SECRET | boris nostr sign --plan plan.json --key-stdin --out bundle.json
boris nostr publish --plan plan.json --bundle bundle.json --out report.json
```

Then delete the secret. Read `classification` in the report. Exit `0` only
means a report was written.

See [`nostr-publication.md`](../../nostr-publication.md).
