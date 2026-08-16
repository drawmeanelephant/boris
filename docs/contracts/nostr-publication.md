# Nostr publication (NIP-23: plan, sign, publish)

**Status:** normative contract for the three-command NIP-23 pipeline.
`boris nostr plan --profile PATH` reads one explicitly selected local
publication profile, selects the allowlisted pages that are eligible as
NIP-23 long-form articles, derives the publication-safe Markdown and tag
set each event would carry, and writes one canonical JSON declaration to
stdout. `boris nostr sign` reads that plan artifact and a secret key from
stdin, computes the exact NIP-01 event id and BIP-340 signature for every
article, and writes a signed-event bundle. `boris nostr publish` reads the
plan and the bundle, re-verifies the bundle against the plan, and delivers
the exact signed events to the plan's relays. The plan slice holds no key
and produces no signature; the sign slice opens no socket and publishes
nothing; the publish slice never sees a secret.

The plan is a report about a website Boris already knows how to build. It
describes what the signing slice will sign and what the publish slice will
send, in enough detail that a maintainer can review the plan before either
step runs. Every fact in the plan is derived from committed content and the
selected profile, so the same inputs always produce the same bytes.

This is an **open program**, not a verified publication target. It has no
location adapter, no evidence-chain Proof Pack, and no live-smoke gate.
GitHub Pages and Standard.site remain the verified targets.

## Scope

The three commands are one pipeline with a hard offline/online boundary.
A successful `plan` run means only that Boris has computed a reviewable
declaration. A successful `sign` run means a verified signed-event bundle
was written. A successful `publish` run means a report was written — the
`complete` / `partial` / `failed` / `incomplete` verdict lives in the
report, never in a collapsed exit boolean.

Explicit non-goals of the program as a whole:

- No NIP-42 relay authentication and no NIP-09 deletion request.
- No key file, key flag, key environment variable, or key prompt. The only
  secret input is `--key-stdin` on `nostr sign`.
- No Nostr client, relay, key manager, or wallet is vendored. Signing uses
  the pinned bitcoin-core/secp256k1 library through a Boris-owned FFI
  wrapper; transport is a bounded in-repo RFC-6455 client.
- Nostr is not a verified target. A completed publish is not a Proof Pack
  claim and does not update `dist/`.

Per-command boundaries:

- `plan` never reads a key, never signs, never opens a socket. `created_at`,
  `id`, and `sig` are absent from the plan: they are signing-time inputs.
- `sign` never opens a socket and never publishes.
- `publish` never reads a key. Configured relay URLs become live endpoints
  only here, and every interaction is bounded.

A bare `boris build` never touches the network. The Nostr surface is a
separate opt-in command family over the same content, so nothing about it
can move bytes into a build. A failed Nostr operation — an ineligible
article, an unportable paragraph, an unnormalizable relay URL, a refused
plan, a signing refusal, a relay timeout — cannot invalidate a built
website. The website is the product; Nostr is a report about it, then an
optional delivery of signed events.

## Protocol authority

Protocol facts come from the pinned NIPs revision, not from memory:

| Field | Value |
|-------|-------|
| Repository | `nostr-protocol/nips` |
| Revision | `656cecc7c0a815b6a2b218d3b5d6f078b3f4dbab` |
| Revision date | 2026-08-08 |
| Verified as repository head | 2026-08-15 (zero drift) |

The pin is documentation authority, not a build dependency: the NIPs are read,
never linked or vendored. Moving it is a deliberate revision bump with a
re-read of the governing NIPs, never an implicit follow of upstream `master`.

| NIP | Governs |
|-----|---------|
| 01 | Event object and tag shape (`kind`, `content`, `tags`, `pubkey`, `created_at`, `id`, `sig`); addressable events in kinds `30000`–`39999` and the `d` tag that names one |
| 23 | Long-form content: kind `30023`, the Markdown profile for `content`, and the `title`, `summary`, `published_at` metadata tags |
| 24 | Extra common tags: `r` for a referenced URL, and lowercase single-word `t` hashtags |
| 73 | External content ids: the `i` tag and its companion `k` tag |

Kind `30023` is addressable, so a NIP-23 article is identified by an address
rather than by an event hash. That single protocol fact drives the whole
[identity and updates](#identity-and-updates) section below.

## CLI

```text
boris nostr plan --profile PATH
```

`--profile PATH` is required and is the only profile-selection mechanism; the
selected profile and its workspace follow the
[publication-profile contract](publication-profile.md). The declaration is
written to stdout and nowhere else: this slice has no output-path flag, so it
cannot overwrite a prior artifact, and it creates no directory, cache, or
report.

The end-to-end pipeline is three commands, one per slice. The secret and the
network are never mixed: signing is the only step that reads a key (once,
from stdin), and publishing is the only step that contacts a relay. A bare
`boris build` never needs a key, a relay, or the network.

```text
boris nostr plan --profile PATH                 # offline → plan JSON on stdout
boris nostr sign --plan PLAN.json --key-stdin   # offline → signed bundle
boris nostr publish --plan PLAN.json --bundle BUNDLE.json   # online → report
```

`nostr sign` re-owns `--out` as the bundle output path and accepts `--prior
PATH` (prior signed bundle for the same address, enabling unchanged-evidence
reuse and the strict `created_at` update ordering below) and `--created-at N`
(explicit unix seconds; test/recovery only). `nostr publish` requires both
`--plan` and `--bundle`, verifies the bundle against the plan before sending
anything, and re-owns `--out` as the report output path. Both commands write
their artifact to `--out` or stdout, and both refuse every other spelling as
a usage error rather than a stub.

Exit codes are shared across the three commands: `1` means an author must
change a page (ineligibility, non-portable Markdown, `ENOSTRSIGN` refusal,
`ENOSTRTIME` ordering violation); `2` means an operator must change the
profile or invocation (missing `--profile`/`--plan`/`--key-stdin`/`--bundle`,
invalid profile, invalid `nostr` section, invalid expected-author `pubkey`,
an enabled section with no publication location, an invalid `--created-at`,
or a plan/bundle over the size bound); `3` is I/O or system failure. For
`nostr publish`, a report is written and exit `0` is returned on any
completed run — the `complete`/`partial`/`failed`/`incomplete` verdict is
carried by the report, never collapsed into an exit boolean. Nothing is
written to stdout on exits `1` and `2`.

## Profile configuration

The Nostr surface is configured by one closed `nostr` section in the selected
publication profile. `boris plan --profile` emits it as a `"nostr"` object only
when it is configured, so an unconfigured profile keeps its current plan bytes
exactly.

| Key | Meaning |
|-----|---------|
| `enabled` | Whether the Nostr surface is configured for this workspace |
| `pubkey` | The expected author public key: 64 lowercase hex characters **or** a NIP-19 `npub1…`. Stored and planned as hex. `npub` never enters a NIP-01 event. |
| `articles` | Exact entity-id allowlist; canonically sorted and deduped |
| `relays` | Relay endpoints, each normalized to `wss://` form, canonically sorted and deduped |
| `timeout_ms` | Declared transport timeout; `publish` uses it as the per-read/write deadline |
| `retries` | Declared transport retry count; `publish` resends identical event bytes this many times after a timeout |

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

The key set is closed: exactly these six keys are accepted, and unknown keys,
duplicate keys, wrong types, and out-of-bound values are rejected by the same
strict profile parser that governs every other profile object. An enabled
section requires a valid `pubkey`, at least one normalizable relay, and a
non-empty `articles` allowlist. A disabled or absent section changes no byte of
any other artifact.

`timeout_ms` and `retries` are declared transport controls, not article
identity. `plan` and `sign` carry them so an operator can review and
version the settings; only `publish` reads them for behavior (per-read
and per-write deadlines, and the retry budget for identical-byte
resends).

`pubkey` is the **expected author public key**. It is public data whose only
purpose is stating which author's address the planned article belongs to, and
whose only enforcement is that a later signing slice must refuse to sign with a
key that does not match it. It is not a credential, and it does not become one
by being configured. A NIP-19 `npub` is accepted as input and converted to
hex before any other work; the closed key set is unchanged.

A secret never appears in a profile, in a plan, or in evidence. There is no
profile key, plan field, or diagnostic message that can carry one, and there is
no environment or file fallback that could introduce one, because this slice
never has a secret to place.

`nostr.enabled` requires a configured `publication` location in the same
profile. The `r` and `i` tags carry the canonical page URL, and a canonical URL
must be the URL that actually serves the page: it is the address a reader
follows off the relay and back to the site. Boris will not synthesize an origin
or guess a base path for a public network, so an enabled section without a
declared publication location is a configuration error.

## Eligibility

The `articles` allowlist is a list of **exact entity ids**. Globs, prefixes,
directory selectors, tag selectors, and status sweeps are all rejected. Putting
an article on a public network is an intentional per-article act, and no
accidental pattern — a broadened glob, a renamed directory, a newly added
draft that happens to match — should be able to reach one. An operator who
wants ten articles published lists ten entity ids.

An allowlisted entity id that is not in the page graph is a configuration
error, not a silent omission: the operator named something that does not exist,
and only the operator can decide whether the id or the content is wrong.

An allowlisted page that exists but cannot be published as NIP-23 is reported
with its reason. The reasons are a closed set and are reported in this fixed
order, so a page with several problems always reports the same first reason:

| Reason | Meaning | Remediation |
|--------|---------|-------------|
| `non-markdown-source` | The page's source is not Markdown (for example a `.textile` or `.cook` page) | NIP-23 defines a Markdown `content` profile; publish a Markdown page, or do not allowlist this one |
| `draft-status` | The page carries `status: draft` | An unpublished draft must not reach a public relay; promote the page's status when it is ready |
| `derived-entity-id` | The entity id was derived from the source path rather than declared by a frontmatter `id:` | Add an explicit `id:` to the page's frontmatter and keep it stable forever |
| `missing-title` | The page has no frontmatter `title` to carry in the `title` tag | Give the page a title; NIP-23 clients list long-form articles by title, and Boris does not derive one from a filename or heading |
| `missing-summary` | The page has no frontmatter `summary` to carry in the `summary` tag | Add a summary; it is the article's abstract in every client index |
| `missing-published-at` | The page has no frontmatter `published_at` to convert into the `published_at` tag | Add the explicit UTC `published_at`; Boris will not substitute a file timestamp or the current time |

The `derived-entity-id` requirement is the one that looks like bureaucracy and
is not. The `d` tag **is** the article's address, and Boris uses the entity id
as `d`. A path-derived entity id changes whenever the file moves: renaming
`notes/why-boris.md` to `essays/why-boris.md` would change `d`, which changes
the address, which makes the next publish a **second article** rather than an
update to the first. The original stays live on every relay that holds it, with
no deletion mechanism in this slice, and readers see two divergent copies. An
explicit frontmatter `id:` makes the address independent of the filesystem, so
an ordinary rename is an ordinary rename.

## Publication-safe Markdown

The `content` field is not the page source. It is a publication-safe view of
the page, computed in this fixed order:

1. **Frontmatter removed.** Frontmatter is Boris configuration, not article
   prose; its facts reach the event as tags, never as content bytes.
2. **Doc-links rewritten** against the publication `base_url`, so every
   documentation reference is an absolute URL.
3. **Includes expanded.** `{{include …}}` is Boris-mediated; a relay cannot
   resolve it, and a reader would see the directive as literal text.
4. **Wiki-links rewritten** against the publication `base_url`. `[[…]]` is
   Boris syntax and its target must become the absolute URL of the served page.
5. **Content-local images absolutized** to their published URLs. A relay has no
   sibling directory, so a relative image source resolves to nothing.

Steps 2, 4, and 5 use the existing `base_url` options already present on the
doc-link, wiki-link, and content-asset seams. With no base URL they render
today's relative form byte-for-byte; the Nostr path is simply the caller that
supplies one.

The resulting view is then validated, and validation is **fail-closed**: an
article is refused rather than published with a defect a reader would see.

| Defect | Why it is refused |
|--------|-------------------|
| Raw HTML (block or inline tag) | NIP-23 `content` is Markdown. A relay client is not a browser and is entitled to escape, strip, or ignore HTML; the author cannot know which |
| Hard-wrapped paragraph | Clients differ on whether a single newline inside a paragraph is a line break. A source-wrapped paragraph renders ragged in some clients and reflowed in others, and the author cannot control which |
| Boris-only component | A Boris component is rendered by Boris. Off-site it is either literal noise or missing content |
| Unresolved relative URL or asset | A relative reference has no meaning outside the site that serves it, and would resolve against the reader's client, not the site |

Validation is **structural**, performed through the Oliver parsing seam over
the typed document rather than by scanning bytes. A code span or fenced code
block containing HTML-looking text is code, not raw HTML, and is never a
defect. This is what makes fail-closed validation usable: an article that
documents HTML is publishable, and an article that emits HTML is not.

An authored line break — two trailing spaces or a trailing backslash — is a
`hard_break` node. It is deliberate authorial intent, it is preserved, and it
is never reported as a hard-wrapped paragraph. The defect is a paragraph broken
by source wrapping, not a break the author asked for.

Reported line and column numbers are 1-based and refer to the
**publication-safe view**, which can differ from the source line when an
include contributed the offending construct. The diagnostic names the page
whose article was refused; a defect contributed by an include is fixed in the
included file.

## NIP-23 mapping

| Event field / tag | Boris source | Classification |
|-------------------|--------------|----------------|
| `kind` | Constant `30023` | required |
| `content` | Publication-safe Markdown view of the page | required |
| `d` | The page's explicit entity id | required |
| `title` | Frontmatter `title` | required |
| `summary` | Frontmatter `summary` | required |
| `published_at` | Frontmatter `published_at` (explicit UTC calendar time) converted to Unix seconds | required |
| `t` | Each frontmatter tag, in source order, in the lowercase single-word form NIP-24 specifies | optional; zero or more |
| `r` | Canonical article URL: publication `base_url` joined with the page's HTML output path | required |
| `i` | The same canonical article URL, as the NIP-73 external content id | required |
| `k` | Literal `web`, the NIP-73 kind for that content id | required |
| `image` | — | omitted in v1: Boris owns no document-image fact, and this pipeline will not promote a body image or a theme asset into article metadata |
| `created_at` | Signing-time Unix seconds (`--created-at N` override, else the wall clock) | absent from the plan; required on every signed event |
| `pubkey` | Profile `nostr.pubkey`, as the expected author | planned as expectation; the signer supplies the real value and must match |
| `id`, `sig` | SHA-256 of the NIP-01 preimage, then BIP-340 over that id | absent from the plan; required on every signed event; verified before the bundle is written and again before publish sends anything |

The `r` and `i` tags both carry the canonical page URL, for two different
reasons: `r` (NIP-24) says the article references that URL, and `i` (NIP-73)
says the article **is** the content at that URL. Together with `k` they let a
client recognize the relay copy and the served page as one document instead of
two.

Tag order is fixed and is part of the plan's identity:

```text
d, title, summary, published_at, t…, r, i, k
```

Authored `t` tags keep their source order; every other position is fixed. Order
is fixed so the planned tag array is comparable byte-for-byte across runs, and
so a reviewer reads the same shape every time.

## Identity and updates

A NIP-23 article's identity is its address, not an event hash:

```text
30023 : pubkey : entity id
```

The plan also emits the NIP-19 display forms of that address (#566). They
are not event tags and they do not enter `intention_digest`:

| Field | Meaning |
|---|---|
| `author.npub` | `npub` of `author.expected_pubkey` |
| `articles[].naddr` | bech32 `naddr` of `(kind, author, d)` plus the plan's `wss://` relays, in that TLV order: `d` (0), author (2), kind (3), each relay (1) |
| `articles[].naddr_uri` | NIP-21 `nostr:` + `naddr` |

`ws://` loopback relays are omitted from the `naddr`. Hex remains the
protocol form. `npub` never appears in a NIP-01 event.

Consequences, all of them normative:

- **Editing content keeps the address.** A corrected paragraph republishes to
  the same address, and a relay replaces the older event. It is an update, not
  a duplicate.
- **Editing metadata keeps the address.** A new title, summary, or tag set is
  still the same article. Only `d` names the article.
- **Renaming a file keeps the address** when the explicit frontmatter `id:` is
  preserved. This is the entire purpose of requiring an explicit id.
- **Changing the `id:` or the `pubkey` is an identity migration.** The address
  changes, so the next publish creates a new article and leaves the old one
  live on every relay that holds it. This slice has no NIP-09 deletion and no
  redirect, so the divergence is permanent until an author acts.

An identity migration must therefore be **visible**, never silently
republished. This slice keeps no side database and compares against no earlier
plan, so it cannot announce that an address changed; what it does instead is
carry the address components — `pubkey`, kind, and the `d` tag — in the plan,
and refuse any selection whose `d` is path-derived (the only way an address
could change without an author editing anything). Two plans therefore diff to
exactly the address change, and choosing to migrate stays an operator decision
with a public, irreversible consequence.

## Determinism

The plan is byte-deterministic. Identical eligible source and identical
configuration produce byte-identical plan bytes, on any host, in any working
directory, at any time of day.

- Fixed object-key order at every level; source key order has no effect.
- UTF-8 with LF line endings, escaped through Boris's shared JSON helper.
- No wall-clock time. The only time value in the plan is `published_at`, which
  is authored frontmatter converted to Unix seconds — never a file mtime, never
  `now`. This is why `created_at` cannot appear: it would be the one field that
  makes every run differ.
- No ambient Git data: no revision, branch, tag, dirty flag, author, or commit
  time.
- No absolute paths, temporary names, workspace root, hostname, username,
  process id, or environment value.
- No secrets, and no field that could carry one.
- `relays` and `articles` are canonically sorted and deduped, so profile
  ordering and duplicated entries cannot change the bytes.
- Tag order is the fixed order above, and authored `t` tags keep source order,
  so tag arrays are comparable across runs.

Determinism is what makes the plan reviewable. A maintainer diffs two plans and
sees only what actually changed about the articles.

## Signing (`boris nostr sign`)

```text
boris nostr sign --plan PLAN --key-stdin [--out PATH] [--prior PATH] [--created-at N]
```

The signer consumes the exact plan artifact `boris nostr plan` emitted and
produces one signed-event bundle. It is offline: no relay, no socket, no
network. A failed signing run never writes a bundle — the artifact is
all-or-nothing, and an error diagnostic means no bundle at all.

### Secret key boundary

- The key is read **once from stdin** (`--key-stdin`, required), as 64
  lowercase hex digits or a NIP-19 `nsec`. It is bounded (128 bytes), trimmed
  of surrounding whitespace, and zeroed best-effort after use.
- The key never enters argv, the profile, the environment, the plan, the
  bundle, diagnostics, logs, or git history. There is no key file and no key
  prompt.
- The signer public key must match the plan's `author.expected_pubkey`. A
  mismatch is a refusal (`ENOSTRSIGN`), never a silent re-identity.
- The BIP-340 dependency is bitcoin-core/secp256k1, pinned at `v0.8.0`
  (PGP-signed tag `18f07c42…`, commit `6e2c8bc4…`, archive sha256
  `eb52b0e9…d17c8bb`) in `build.zig.zon`; see the dependency record in
  `src/nostr_keys.zig`. Signing uses `secp256k1_schnorrsig_sign32` — the
  32-byte NIP-01 event id is signed directly, with the BIP-340 nonce function
  (`BIP0340/nonce`); RFC6979 is ECDSA's nonce derivation and is not on this
  path.
- **Auxiliary-randomness policy**: production signing passes fresh 32-byte
  CSPRNG bytes as BIP-340 auxiliary randomness and fails closed if they cannot
  be obtained. The context is additionally randomized for side-channel
  hardening; neither changes signature output. Conformance tests inject fixed
  aux bytes so expected signatures are reproducible.

### NIP-01 event id and signature

For every article, the event id is the SHA-256 of the exact canonical NIP-01
preimage, with no whitespace:

```text
[0, "<pubkey hex>", <created_at>, 30023, [<tags>], "<content>"]
```

Content and tag values are escaped exactly as `JSON.stringify` escapes them
(`\"`, `\\`, `\b`, `\f`, `\n`, `\r`, `\t`, `\u00xx` for other control bytes;
non-ASCII stays raw UTF-8). The signature is the BIP-340 Schnorr signature of
that 32-byte id. The signature is verified against the event id before any
bundle bytes are written; the bundle records `signature_verified: true` only
for events that passed.

### `created_at` and update ordering

- `created_at` is a **signing-time input**: current Unix seconds by default,
  or an explicit `--created-at N` test/recovery override. It is never a
  build-phase value.
- `created_at` must be at least the article's authored `published_at`
  (`ENOSTRTIME` otherwise).
- With `--prior PATH` (a prior signed bundle), an **unchanged** intention
  reuses the exact prior signed event — same id, signature, and `created_at` —
  so republishing identical content never churns signatures or timestamps.
- A **changed** intention requires the new `created_at` to be **strictly
  greater than** the prior event's `created_at`. Kind `30023` is addressable
  and relays break same-`created_at` ties by event-id ordering, so a same- or
  older-`created_at` update would silently lose to the prior event. When the
  wall clock cannot satisfy the rule (same-second rapid update, or a future
  prior timestamp) the run fails deterministically with `ENOSTRTIME` unless an
  explicit `--created-at` override satisfies it. The signer never emits a
  weaker event that some relays would discard.
- A prior bundle from a different identity is refused (`ENOSTRPLAN`): reuse
  is only ever within one author.

### The signed-event bundle

```json
{
  "format": "boris-nostr-signed-bundle",
  "schema_version": 1,
  "protocol": { "nips_revision": "…", "research_date": "…", "kind": 30023 },
  "plan": { "format": "…", "schema_version": 1, "digest": "<sha256 of the exact plan bytes>" },
  "signer": { "pubkey": "…", "created_at_policy": "signing-time" },
  "articles": [
    {
      "entity_id": "…", "d": "…",
      "intention_digest": "…", "disposition": "signed|reused",
      "created_at": 1705762000, "published_at_unix": 1705761000,
      "event_id": "…", "signature": "…", "signature_verified": true,
      "event": { "id": "…", "pubkey": "…", "created_at": 1705762000,
                  "kind": 30023, "tags": [[…]], "content": "…", "sig": "…" }
    }
  ]
}
```

The bundle is byte-deterministic for identical plan bytes, key, aux, and
`created_at`; it is bound to the exact plan bytes by the `plan.digest`. The
signed `event` object is the NIP-01 wire event a publish slice would send
verbatim.

## Publishing (`boris nostr publish`)

The publish slice sends the exact signed `event` objects from a bundle to the
plan's `delivery.relays` and writes a canonical report. It never re-signs and
never touches a secret: the bundle was signed offline by `nostr sign`, and
publishing only re-transmits it. Nothing is sent before the bundle is
cross-verified against the plan — the bundle's `plan.digest` must match the
sha-256 of the exact plan bytes, `bundle.signer.pubkey` must equal the plan's
`author.expected_pubkey`, the bundle's article set must be exactly the plan's
article set (same `entity_id` values, no extras, no omissions), every
article's event id must match the NIP-01 preimage of its event, and every
signature must verify.

### Transport contract

- Relay URLs are `ws://` or `wss://` with an explicit host and optional
  port/path. `ws://` is refused for any non-loopback host (`localhost`,
  `127.0.0.1`, `[::1]`): plaintext WebSocket is a loopback/test convenience
  only.
- Named hosts are resolved with `Io.net.HostName` (DNS lookup, then connect
  to the returned addresses). `Io.net.IpAddress.resolve` parses IP literals
  only and is not a hostname resolver; using it for `wss://relay.example.org`
  is `ResolveFailed` (#545). IP literals (`127.0.0.1`, `[::1]`) stay on the
  literal path so mock-relay fixtures are unchanged.
- `wss://` uses `std.crypto.tls` with explicit hostname verification and a
  real CA bundle (system roots). A 0-byte TLS read with an empty
  application buffer is not a failed upgrade: TLS 1.3 post-handshake
  messages (`NewSessionTicket`) and a partial ciphertext record both
  surface that way. The client keeps reading until application data,
  `close_notify`, or the deadline (#552).
- The opening handshake is validated exactly: status `101`, `Upgrade:
  websocket`, `Connection: Upgrade`, and `Sec-WebSocket-Accept` computed over
  the client key + `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`.
- Client frames are always masked (RFC 6455 §5.1); a **masked server frame is
  a protocol error**. Control-frame payloads over 125 bytes, fragmented
  control frames, unknown opcodes, and payloads over the declared ceiling are
  protocol errors. Outgoing text messages larger than
  `max_fragment_bytes` (64 KiB) are themselves fragmented on the wire — an
  initial text frame with FIN clear, then continuation frames — as every
  conforming server must accept. Message reassembly is bounded by a size
  ceiling, and every read and write is individually bounded by a deadline
  (the plan's `delivery.timeout_ms`), so no relay interaction can hold the
  run open.
- The client answers `Ping` with `Pong` and honors `Close`; a relay that
  closes before an `OK` is classified `closed`.

### Per-relay evidence and classification

Each relay produces one outcome per event and one relay-level status:

| Event result | Meaning |
|---|---|
| `accepted` | An `OK` with `true` matched the sent event id |
| `rejected` | An `OK` with `false` (reason kept as the message) |
| `auth-required` | An `OK` whose reason starts with `auth-required:` — NIP-42 is out of v1 (#493), reported honestly as unsupported, no retry |
| `wrong-id` | An `OK` named a different event id — fail closed |
| `timeout` | No `OK` within the deadline (retried, identical bytes, per `delivery.retries`) |
| `closed` | The relay closed the connection before an `OK` |
| `error` | Connect/handshake failure or a relay protocol error |
| `not-attempted` | A later event skipped after a definitive failure for that relay |

The run-wide verdict is `complete` (every relay accepted every event),
`partial` (at least one relay accepted at least one event), `failed` (no
relay accepted anything), or `incomplete` (at least one relay timed out and
nothing was accepted). The report lists each relay with its URL, outcome,
attempt count, and per-event evidence; the classification is the last field.
A `failed` or `auth-required` relay is not attempted again for later events.

### The publish report

```json
{
  "format": "boris-nostr-publish-report",
  "schema_version": 1,
  "plan": { "format": "…", "schema_version": 1, "digest": "<sha256 of the plan bytes>" },
  "bundle": { "format": "…", "schema_version": 1, "digest": "<sha256 of the exact bundle bytes>" },
  "signer": { "pubkey": "…" },
  "classification": "complete|partial|failed|incomplete",
  "relays": [
    {
      "url": "wss://relay.example.com/",
      "outcome": "accepted",
      "attempts": 1,
      "events": [
        { "entity_id": "…", "event_id": "…", "result": "accepted", "message": "" }
      ]
    }
  ]
}
```

Every relay interaction is bounded and produces a verdict, so the run always
writes a report. A static golden example lives at
[`docs/contracts/fixtures/nostr-publication/expected/publish-report.json`](fixtures/nostr-publication/expected/publish-report.json).

### Conformance matrix

A hostile mock-relay matrix (`nostr_publish_matrix_test.zig`) drives the real
client over loopback: honest accept, fragmented `OK` reassembly, `Ping` before
`OK` (answered with `Pong`), `NOTICE` then `OK`, close-before-`OK`, a masked
server frame, a silent relay, `auth-required`, an `OK` for the wrong event id,
non-JSON garbage, an oversized frame, a bad handshake, a retry that re-sends
identical event bytes, and a mixed two-relay run classified `partial`.

Two additions exercise the parser and the TLS path directly. A fuzz-stream
scenario feeds random frames (random opcodes, lengths, mask bits, fin flags)
to the client's frame reader and asserts it fails closed without hanging or
crashing; the same seeded round-trip drives `encodeFrame`/`parseFrame`
consistency. And a real `wss://` end-to-end test runs a TLS mock relay
(`scripts/nostr-mock-relay-tls.py`, Python `ssl`) pinned by committed
self-signed test credentials
([`fixtures/nostr-publication/tls/`](fixtures/nostr-publication/tls/)): the
positive case asserts the full publish round-trip completes over TLS, and a
negative case pins the same CA but connects to `127.0.0.1` to assert
hostname verification fails closed.

The write side is fuzzed against a recording mock relay: random payloads
and fragmentation patterns (fragment sizes 1 through 65536, payload lengths
across every length-encoding boundary) travel through `sendText` over a real
loopback socket, and the relay's record — mask bit, FIN sequence, length
codes, and the unmasked payload — is asserted byte-exact against what was
sent. A separate test covers the write deadline: a relay that completes the
handshake and then stops reading forces the client's flush to block, and the
per-write deadline must interrupt it mid-flush (`WriteTimeout`) rather than
hang. Both mock relays (in-repo and Python TLS) reassemble fragmented client
messages, as a conforming server must.

## Diagnostics

Five codes are emitted by the pipeline, all at `error` severity; see the
[diagnostics contract](diagnostics.md) for the shared object, text form, and
ordering.

| Code | Phase | Exit |
|------|-------|-----:|
| `ENOSTRELIGIBILITY` | Eligibility selection: an allowlisted page cannot be published as NIP-23, its entity id is absent from the page graph, or an authored tag is not a valid `t` topic | `1` |
| `ENOSTRMARKDOWN` | Publication-safe Markdown validation: the view carries a fail-closed defect, or a doc-link, wiki-link, include, or content-local image does not resolve | `1` |
| `ENOSTRTIME` | Plan: the authored UTC `published_at` does not convert to a Unix second count. Sign: `created_at` precedes `published_at`, or a changed intention needs a strictly newer `created_at` than the prior event (NIP-01 tie-break) | `1` |
| `ENOSTRPLAN` | Plan assembly against a corpus that changed under the run, or a signer input that is not a valid plan/prior artifact (wrong format, wrong schema, `d` mismatch, intention-digest mismatch, prior from a different identity) | `1` |
| `ENOSTRSIGN` | Signing refusal: the secret key is malformed, the signer public key does not match the plan's expected author, the secp256k1 context or aux randomness is unavailable, or a signature fails to self-verify before the bundle is written | `1` |

`ENOSTRRELAY` is emitted by the **publish slice only** — the offline slices
never touch a relay. Relay configuration is still refused earlier and harder,
by the strict profile parser, as an invalid `nostr` section (exit `2`) —
before any content is read. During publish, a relay is a live endpoint that
can reject, time out, close, or demand authentication; each relay attempt is
bounded, each failure emits an `ENOSTRRELAY` diagnostic, and the per-relay
evidence in the report keeps the run's verdict honest.

Configuration failures do not use a diagnostic code at all. A missing
`--profile`, an invalid profile, a malformed `nostr` section, a disabled
section, an invalid expected-author `pubkey`, an enabled section with no
publication location, a missing `--plan`, or a missing `--key-stdin` are all
usage errors reported on stderr with exit `2`, because none of them is a
statement about content.
