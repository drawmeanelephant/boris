# Nostr publication (NIP-23: plan, sign, publish)

**Status:** normative contract for the three-command NIP-23 pipeline.
The [approved NIP-42 boundary](#approved-nip-42-boundary-phase-1-1002)
governs the opt-in phase-2 implementation. Its scoped macOS fault-injection
proof passes, as recorded below. It remains unreleased and does not amend
ordinary v1 behavior.
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

This is an **open program**, not a verified publication target. That is a
decision, not a missing slice. Relays are not a host: they have no
`base_url` / `origin` / `base_path`, they do not hold a committed
artifact inventory, and a `complete` report is not a Proof Pack claim.
The three-command family, the per-relay verdict, and the recorded
first-tester fixture at
[`fixtures/nostr-live-smoke/`](fixtures/nostr-live-smoke/README.md) are
the Nostr-shaped evidence. GitHub Pages and Standard.site remain the
verified targets. Do not add `nostr` to the target registry to make this
CLI feel finished.

#584 asked for registry membership or for the explicit reason it stays off;
the reason is recorded as a decision in
[`publication-platforms.md`](publication-platforms.md) ("Recorded decision:
Nostr stays off the seam"). The verified-target extras — a location adapter, a
Nostr Proof Pack claim, and a required live-smoke gate — stay unbuilt with it.

## Scope

The three commands are one pipeline with a hard offline/online boundary.
A successful `plan` run means only that Boris has computed a reviewable
declaration. A successful `sign` run means a verified signed-event bundle
was written. A successful `publish` run means a report was written — the
`complete` / `partial` / `failed` / `incomplete` verdict lives in the
report, never in a collapsed exit boolean.

Explicit non-goals of the program as a whole:

- No implicit NIP-42 relay authentication and no NIP-09 deletion request.
- No key file, key flag, key environment variable, or key prompt. The only
  secret input is `--key-stdin` on `nostr sign`.
- No Nostr client, relay, key manager, or wallet is vendored. Signing uses
  the pinned bitcoin-core/secp256k1 library through a Boris-owned FFI
  wrapper; transport is a bounded in-repo RFC-6455 client.
- Nostr stays off the verified-target seam. A completed publish is not a
  Proof Pack claim and does not update `dist/`.

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

The relative-URL row covers every link and image destination in the
publication-safe view, not only the four mediated classes. A destination is
acceptable when it is scheme-qualified (`https:`, `mailto:`, `nostr:`, …) or
origin-qualified (`//host/…`); a bare, root-relative, query-only, or
fragment-only reference is refused, because none of them resolve against the
site that serves the article. The mediated classes are rewritten against the
publication `base_url` before this check, so a reference that remains relative
is one Boris could not resolve off-site.

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

When the HTML build is invoked with `--profile PATH` and that profile has
`nostr.enabled`, each eligible allowlisted page also receives one
compiler-owned head link (`<link rel="alternate" href="nostr:naddr1…">`)
in the `{{head}}` slot (#571). Eligibility is the same closed set as
`boris nostr plan` except Markdown-body inspection: a hard-wrapped
paragraph or raw HTML still fails the plan, not the HTML build. A bare
`boris` build without `--profile` emits no Nostr links. A layout that
omits `{{head}}` warns `ENOSTRHEAD` and still succeeds.

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
  hex digits (either case) or a NIP-19 `nsec`. It is bounded (128 bytes), trimmed
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
A dated public-relay run, including its `partial` classification and per-relay
outcomes, is checked in at
[`fixtures/nostr-live-smoke/`](fixtures/nostr-live-smoke/README.md). That
fixture is not a required gate.

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

## Approved NIP-42 boundary (phase 1, #1002)

**Status: phase-1 boundary approved on 2026-10-01; phase-2 implementation
authorized separately; implemented and tested on macOS, awaiting review.**
The requirements below remain the
approved boundary, not a reduced implementation acceptance checklist.
Refs [#1002](https://github.com/drawmeanelephant/boris/issues/1002).
The [#493 v1 decision](https://github.com/drawmeanelephant/boris/issues/493)
stands: unsupported authentication is a **Documented limitation**, not a
defect. Everything in this section is an approved post-v1 design requirement. The
current CLI, six-key profile grammar, artifact schemas, offline signer, and
`auth-required` outcome above remain authoritative for shipped behavior.
This design adds neither a verified publication target nor a Proof Pack claim.

### Protocol revision and evidence

On **2026-10-01**, re-read the complete official
[NIP-42](https://github.com/nostr-protocol/nips/blob/656cecc7c0a815b6a2b218d3b5d6f078b3f4dbab/42.md)
and
[NIP-01](https://github.com/nostr-protocol/nips/blob/656cecc7c0a815b6a2b218d3b5d6f078b3f4dbab/01.md)
at **`656cecc7c0a815b6a2b218d3b5d6f078b3f4dbab`** (commit date
2026-08-08). This is the existing pin, not a claim that upstream head still
matches it. Phase 2 must re-read these pinned texts and record any deliberate
revision change before implementation.

The governing facts are:

- NIP-42 is `draft`, `optional`, `relay`. The relay sends
  `["AUTH", <challenge-string>]`; the client sends
  `["AUTH", <signed-event>]`, and the relay must answer with an `OK`.
- **The challenge is an untrusted string, not a signed relay statement.**
  There is no challenge signature or timestamp to verify. Transport peer
  authentication, exact connection association, local lifetime limits, and
  verification of **our response event** are the checks Boris can perform.
- The response is kind `22242`, with the received challenge and relay URL
  tags and a current `created_at`. NIP-01 makes that kind ephemeral; NIP-42
  says it is not meant to be published or queried and relays must not
  broadcast it. Ephemeral describes the **event**, not a new secret key.
- A challenge lasts for its connection or until a new challenge replaces it.
  NIP-42 permits challenges at any moment, including around a denied
  operation; it does not guarantee a proactive challenge.
- NIP-01's canonical event-id preimage and BIP-340 signature rules apply.
  An auth `OK` names the **auth event id**, not the article id.
  `auth-required:` means authentication is needed; `restricted:` means the
  authenticated identity is not authorized for the operation.

Current-code evidence at `main` revision `08969742`: `sendEvent` in
`src/nostr_publish.zig` sends the article before `readUntilOk`; the latter
classifies `AUTH` or an `auth-required:` rejection as unsupported. The
`auth-required` and mixed-relay cases in `src/nostr_publish_matrix_test.zig`
pin that v1 behavior. Phase 2 must insert an opt-in pre-article gate in this
publisher, not build a second transport or publisher.

### Decision: a scoped sign-session supervisor, a keyless publisher

Keep ordinary `nostr sign` entirely offline. Add a **separate, explicit mode
of `nostr sign`** that holds the author key while supervising a keyless
`nostr publish` child. The supervisor itself opens no network connection;
only the child uses the existing WebSocket client. The two processes exchange
bounded public requests and signed auth events over private anonymous pipes.
No secret, derived secret, keypair, nonce seed, secp256k1 context, or signing
auxiliary randomness is returned to the child.

Explicit session invocation (currently macOS only):

```text
boris nostr sign --auth-session --plan PLAN --bundle BUNDLE --key-stdin \
  [--report-out REPORT]
```

This mode does not sign articles or create a bundle. The existing offline
`nostr sign --plan PLAN --key-stdin [--out BUNDLE]` runs first, in a different
invocation. Session mode requires its already-signed bundle, rejects
`--prior`, `--created-at`, and bundle `--out`, and forwards the child's
publish report to stdout or `--report-out`. There is no production auth-time
override. The only secret-input spelling remains `--key-stdin` on
`nostr sign`; `publish` has no secret input.

The supervisor launches the same trusted Boris executable by its resolved
executable path, not through a shell, `PATH` lookup, profile command, or
external helper. Its private session mode is not a public general-purpose
signing service. There is no named pipe, listening socket, key file, daemon,
environment credential, or signer plugin in this slice.

#### Custody and startup order

1. Both processes validate the exact plan/bundle and their bindings before
   network work. Public session policy fixes the plan and bundle SHA-256
   digests, protocol revision, expected author, opted-in relay subset, and
   timeout. No mutable profile is re-read during the session.
2. **Spawn and complete the child's exec before reading the key.** Wait for
   the child's bounded, versioned `ready` handshake; it must wait for `begin`
   before opening any relay socket. This avoids copying a key-bearing
   supervisor address space into a forked publisher. Do not fork another
   child after key ingestion.
3. The child gets `/dev/null` as stdin and only its two pipe endpoints,
   report stdout, and diagnostic stderr. It must not inherit the
   supervisor's key-input descriptor, unrelated descriptors, or a key
   buffer. Pipe handles are supplied by the launcher, never the profile or
   environment; all unrelated handles are close-on-exec.
4. The supervisor reads the bounded hex/`nsec` key once from its own stdin
   under the existing 128-byte policy. Derive the public key and require
   equality with the plan and bundle signer. On failure, terminate/reap the
   waiting child; no network operation has begun. Only then send `begin`.
5. The key and secp256k1 signing context remain in supervisor memory for this
   invocation only. Disable core dumps before key ingestion; use the
   existing fresh-aux-randomness and signature-self-verification policy.
   Zero input/key/aux buffers best-effort and destroy the context on all
   handled exit paths. No persistence or crash-recovery credential exists.

| Boundary | What crosses it | What does not cross it |
|---|---|---|
| Operator stdin → sign supervisor | One long-lived author secret, hex or `nsec` | No argv/env/profile/file fallback |
| Supervisor → publish child | Public policy, session controls, signed kind-22242 response | No secret key or secret signing state, including at process creation |
| Publish child → supervisor | Relay-bound opaque challenge and public correlation fields | No arbitrary signing preimage, hash, event, content, kind, or tags |
| Publish child → relay | Verified `AUTH` event; after its matching positive `OK`, the original article `EVENT` | No key; no changed/re-signed article; no auth event sent as `EVENT` |
| Either process → output/evidence | Public outcomes and bounded machine reasons | No key input, raw challenge, raw auth event, pipe transcript, or raw signer error |

The supervisor is trusted with custody and the publisher is trusted to
associate a challenge with the actual verified transport. The supervisor
cannot independently prove that a string arrived on that connection; there
is no signed relay challenge. A compromised publisher can request a bounded
number of auth proofs for the explicitly allowed relays, but cannot ask this
interface to sign an article, arbitrary digest, or another kind. A compromised
supervisor can expose its key: this design does not claim protection from a
compromised signer, kernel, or same-user process debugger. Process separation
is a narrow data/API boundary, **not an OS sandbox or hardware key store**.
Platform launch/descriptor behavior must be proved in phase 2; a platform
that cannot meet the custody rules must reject session mode.

An offline extra auth step cannot predict a live connection's challenge.
A throwaway key is not a substitute for the relay's authorized identity, and
NIP-42 at this pin supplies no delegation from the author to that key. The
first slice uses exactly the planned author; multi-identity auth and remote
signers are out of scope.

### Opt-in declaration and compatibility

Propose one optional, closed profile object:

```json
"auth": {
  "mode": "nip42",
  "relays": ["wss://auth-relay.example.org"]
}
```

It lives under `nostr`, has exactly `mode` and `relays`, and opts in only the
named relays. Normalize/sort/dedupe with Boris's existing relay normalizer;
require a non-empty subset of `nostr.relays`, an enabled Nostr section, and
URLs at most 1,024 UTF-8 bytes. The expected auth identity is
`nostr.pubkey`; there is no separate credential or executable declaration.
Unknown keys/modes, duplicate keys, wrong types, and out-of-bound values fail
preflight. The existing implementation limit of **32 relays** still bounds
the session. The phase-1 text incorrectly called the existing limit 256;
phase 2 retains the actual limit rather than expanding v1 behavior.

Carry the static subset as `delivery.auth` in opt-in Nostr plans. An opt-in
plan, bundle, publish report, and general publication-plan declaration use a
deliberately versioned **schema 2**. The profile keeps its additive schema-1
grammar extension; old strict profile parsers already reject `auth` as an
unknown key. Phase 2 updates the affected profile/plan
contracts, parsers, and focused fixtures together. Old consumers must refuse
the new version, not silently ignore required authentication. Plan digests
bind the auth policy, but article intention digests and NIP-23 wire events
do not change merely because transport auth is enabled.

With `auth` absent, retain current schema-1 bytes, CLI behavior, offline
signing, relay ordering, retries, diagnostics, and classification exactly.
Do not emit `"auth": null`, spawn a supervisor, or wait for a challenge on
that path. For relays outside the subset in a session run, use the existing
unauthenticated publish path; an unexpected auth demand remains
`auth-required`, never automatic consent to authenticate. Thus a mixed plan
can publish normally to unauthenticated relays.

An opt-in publish requires the live private signer session. A direct
`nostr publish` without it refuses the invocation before any sockets open
(exit 2); it must not silently drop the opt-in policy or read a key instead.
Ordinary `plan` and bundle `sign`, including opt-in plans, remain offline.
No challenge, auth timestamp, connection nonce, auth signature, auth event
id, or observed relay outcome enters a plan or signed article bundle.

### Minimal signer interface

Use two unidirectional anonymous pipes, a four-byte big-endian length prefix,
and strict UTF-8 JSON payloads. Version the handshake and every message as
`boris-nostr-auth-ipc` version `1`; reject unknown/duplicate keys, trailing
bytes, wrong types, unexpected messages, and lengths over **32,768 bytes**
before allocation. JSON nesting is capped at eight containers. Private
correlation tokens are public randomness, not credentials, and are not
persisted in the report.

Each sign request contains only:

- The session's plan/bundle digests and protocol revision.
- The supervisor's fresh 128-bit run nonce from the handshake, the child's
  fresh 128-bit connection nonce, monotonically increasing request number,
  normalized relay URL, and generation `1` or `2`.
- The exact decoded challenge string.

The supervisor independently compares every policy field, bounds the
challenge, and enforces the per-relay generation/request budget. It generates
`created_at` from its clock and constructs the event itself. The publisher
cannot supply a kind, timestamp, tags, content, event id, or digest to sign.
One request is outstanding at a time, matching the existing sequential relay
loop. At most two requests per opted-in relay are allowed for the whole run.
Close/retire a connection with an explicit control message; it cannot later
be reactivated. No reconnect or auth retry opens an additional budget.

The response echoes all correlation fields except the challenge and contains
only a structured refusal code or the signed auth event. The event necessarily
contains the challenge tag; there is no second challenge copy or secret
response field. Both processes check current generation and request identity,
and neither treats successful IPC or signer self-verification as relay
authentication success.

Cancellation on replacement invalidates the old request, even if its response
is already in flight. A response for a retired request is discarded without
sending `AUTH`; duplicate or otherwise unexpected responses fail the session.
A signer refusal affects its relay; other relays continue. A persistent
signing failure reported over a healthy channel disables authentication for
remaining opted-in relays, while the publisher still attempts non-opted-in
relays. Broken IPC, malformed session controls, or supervisor death instead
cancel the whole session: no publisher is allowed to run orphaned. Never fall
back to unsigned auth or secret ingestion.

Startup, key input, and each complete IPC frame use `delivery.timeout_ms`,
with non-renewing monotonic deadlines. Between requests the supervisor may
wait while the child visits ordinary relays, but both enforce a **600,000 ms
total session ceiling** from `begin`; progress cannot renew it. All relay
and auth deadlines are clipped to that remaining budget. At this ceiling,
stop new writes, report unfinished relays as `timeout` / `session-timeout`
with remaining articles `not-attempted`, and preserve accepted evidence.
This cap applies only to opt-in session mode. The supervisor erases custody,
allows 1,000 ms for the child's report/exit, then terminates/reaps it if needed;
an unfinished report is a system failure, not a fabricated completed verdict.

On channel EOF or explicit cancellation, the supervisor erases custody and
terminates/reaps its own child, escalating after **1,000 ms** if necessary.
The child monitors supervisor/channel liveness during network and IPC waits
and stops on loss. Teardown cannot turn cancellation into a success report.

### Relay gate, challenge lifetime, and response verification

**Choose proactive-only authentication for this first slice.** On an opted-in
connection, wait for a valid challenge before sending any article. If the
relay waits for a denied `EVENT` before issuing `AUTH`, this mode times out
and sends no article; there is no speculative article, probe `REQ`, guessed
challenge, or fallback to the NIP-42 denied-write/retry example. Such relays
are a documented compatibility limitation. Supporting them would require a
separate reviewed consent/acceptance change, because sending the initial
article contradicts the requested pre-article gate.

For each opted-in relay:

1. Verify the existing WebSocket upgrade and, for production `wss://`, CA
   chain and hostname before requesting a signature. Plain `ws://` remains
   loopback-test-only, never evidence of an authenticated remote peer.
   Bind the response to the **configured normalized URL**, including scheme,
   non-default port, and path; no redirects, challenge-provided URL, DNS
   address substitution, or domain-only match is allowed.
2. Accept exactly a two-element `["AUTH", string]` message. Require valid
   UTF-8 and 1–4,096 decoded bytes; reject C0 controls and DEL as a Boris
   local safety policy, not a NIP-42 requirement. Do not trim, case-fold, or
   Unicode-normalize the challenge. The auth-phase incoming message ceiling
   is 32,768 bytes, including fragmented reassembly. Oversize declarations
   fail before oversized allocation. Malformed frames/JSON fail this relay.
3. Track `(run, connection, relay, generation, challenge)` in transient
   memory. A challenge is active only on that live connection. Remember
   challenge SHA-256 values per normalized relay for this run: seeing the
   same decoded challenge again, even after replacement, fails as `replay`.
   There is no durable replay database and no claim to detect reuse across
   invocations or prove a relay's challenge randomness or issuance time.
4. Use a monotonic deadline of `delivery.timeout_ms` to obtain the first
   challenge, then one **non-renewing** auth deadline of
   `min(3 * delivery.timeout_ms, 60_000)` ms from its receipt. Its local
   lifetime covers signing, verification, sending `AUTH`, and receiving
   the matching `OK`. Individual operations also retain their existing
   read/write deadlines, clipped to the remaining auth budget. `NOTICE`,
   Ping/Pong, fragments, partial IPC, and replacement never extend the
   absolute deadline. This bounds trickle traffic as well as silence.
5. Allow **one distinct replacement before the first article is sent**.
   Retire generation 1, cancel its signer request/auth wait, and sign only
   generation 2 under the original auth deadline. Ignore late `OK`s only
   for the explicitly retired auth id, within that same bounded wait.
   A third challenge, repeated challenge, or unrelated `OK` fails closed.
   If the first auth had succeeded but no article has yet gone out, a
   replacement closes the gate until its own positive `OK`.
6. The supervisor constructs exactly the NIP-01 fields below. It computes
   and self-verifies the id/signature using the existing pinned secp256k1
   wrapper, fresh CSPRNG aux bytes, and randomized context:

   ```text
   pubkey     = plan.author.expected_pubkey
   created_at = current Unix seconds from the supervisor
   kind       = 22242
   tags       = [["relay", normalized_relay_url], ["challenge", exact_challenge]]
   content    = ""
   id         = SHA256(UTF8 canonical JSON [0,pubkey,created_at,22242,tags,""])
   sig        = BIP-340 signature of that 32-byte id
   ```

7. Before sending `AUTH`, the publisher independently checks the response's
   exact correlation, active challenge/generation/connection, unexpired
   monotonic deadline, expected public key, exact kind/content/two ordered
   two-string tags, and absence of extra event fields. Require integer Unix
   seconds within **60 seconds** of its current wall clock; a clock jump
   outside that tolerance fails, never widens the bound. Recompute the
   canonical NIP-01 preimage and lowercase 64-hex event id, and verify the
   lowercase 128-hex BIP-340 signature. The stricter local freshness bound
   is distinct from NIP-42's illustrative approximately ten-minute relay
   check. Mismatch, stale response, id/signature failure, or oversized
   signer output sends neither auth nor article.
8. Send the verified event **once** as `["AUTH", event]` on that same
   connection, never to other relays, never as `EVENT`, never persisted.
   Accept only an exact four-element `["OK", auth_id, boolean, string]`;
   `NOTICE`, signing completion, `auth-required:`, and an article's `OK`
   are not auth success. Matching `true` opens the article gate; matching
   `false` is rejection. Wrong id, malformed `OK`, Close, or deadline
   failure closes this relay without sending an article.
9. Only after that positive `OK`, send the exact already-verified NIP-23
   wire event with the existing serializer. Never change its id, timestamp,
   signature, tags, or content. Identical-byte article timeout retries may
   run on this authenticated connection; `delivery.retries` does **not**
   retry authentication, rejection, or protocol failure.

While signing, the publisher must keep processing the live connection to
observe replacement, Ping, and Close within the same budgets. Before each
article write, process already-buffered relay control messages and check the
gate. After any article write, a new `AUTH` terminates this slice's relay
session rather than starting another signing round; an `auth-required:`
article rejection also stops later writes. Preserve already accepted article
evidence. If an article is in flight without an `OK`, report its acceptance
as unknown (`timeout` with no further retry), not definitively rejected.
Remaining articles are `not-attempted`.

The no-article guarantee covers any failure **observed before the associated
write**. A relay can send a replacement concurrently with a write or after
receiving earlier articles; neither the protocol nor a local client can
unsend those bytes. Do not claim atomic challenge validity across two peers,
global replay prevention, or reversal of accepted articles.

### Per-relay evidence, diagnostics, and run classification

Schema-2 reports retain article outcomes separately from an `auth` object
on each relay. A non-opted-in relay has auth status `not-requested`.
The object records the public expected auth pubkey, final status, bounded
reason code, phase, signing-request count, actual AUTH-send count, and up to
two exchange records containing generation, public auth event id and
`created_at` when available, and result (`authenticated`, `rejected`,
`superseded`, `timeout`, `closed`, `protocol-error`, or `signer-error`).
Missing facts are null, never fabricated. These are temporal publish
observations, not deterministic plan/bundle facts.

| Final auth status | Meaning | Relay delivery outcome before any article |
|---|---|---|
| `not-requested` | Relay outside opt-in subset | Existing v1 outcome |
| `authenticated` | Matching positive auth `OK`; connection not subsequently invalidated | Determined only by article results |
| `rejected` | Matching negative auth `OK` | `auth-required` for that prefix; otherwise `rejected` |
| `timeout` | Challenge, signer, AUTH write, or auth `OK` missed its bounded deadline | `timeout` |
| `closed` | Relay closed before authentication completed | `closed` |
| `protocol-error` | Malformed, oversized, replayed, stale, or mismatched challenge/response/`OK`, or replacement policy violation | `error` |
| `signer-error` | Key/signing/session refused or signer channel unavailable | `error` |

Use a closed reason vocabulary: `not-opted-in`, `challenge-timeout`,
`signer-timeout`, `auth-write-timeout`, `auth-ok-timeout`, `malformed`,
`oversized`, `replay`, `stale`, `relay-mismatch`, `identity-mismatch`,
`event-id-mismatch`, `signature-invalid`, `unexpected-ok`,
`replacement-limit`, `replacement-after-event`, `auth-required`,
`restricted`, `relay-rejected`, `relay-closed`, `session-timeout`, `signer-refused`,
`signer-unavailable`, and `session-invalid`. Record standardized rejection
prefixes, not arbitrary human text from auth replies. A later replacement
or auth demand updates the final auth status without rewriting its earlier
successful exchange or article acceptance.

Continue to other relays after a local failure. Emit `ENOSTRRELAY` with
relay URL, auth phase, and fixed reason/remediation text; never interpolate
the challenge, key input, auth event, IPC payload, or signer error string.
Auth event ids, signatures, and pubkeys are public, but signatures/full auth
events and challenge hashes are deliberately not report fields. The
supervisor's refusal diagnostics follow the same no-input-echo rule.

Before the gate opens, every article is `not-attempted`, with zero article
attempts; auth attempts do not inflate the existing `attempts` field.
Schema-2 classification must also consider relay-level auth timeouts, so
unsent articles cannot hide them: `complete` requires every article accepted
by every relay; `partial` requires at least one accepted article without
universal acceptance; with none accepted, `incomplete` means any unresolved
relay/auth timeout, otherwise `failed`. **Auth success alone never counts
as article acceptance.** A post-auth `restricted:` article result remains
a publication rejection, with the successful auth exchange preserved.

Startup usage/identity refusal retains the existing exit classes and opens
no sockets. After a publish run begins, write the bounded per-relay report
and retain publish exit 0 for a completed report regardless of verdict;
report-write/system failure is exit 3. Session supervision relays that exit
status, not a boolean meaning "auth worked." Cancellation is not a
completed run and must not fabricate a final report.

### Phase-2 test plan

Extend `src/nostr_publish_matrix_test.zig` and focused Nostr signing/parser
tests under the existing `zig build test-nostr` / `zig build test` gates.
Use hostile loopback recording relays and injected clocks/aux bytes; retain
the existing WebSocket/TLS mock paths. No public relay, author credential,
credential store, browser, or required live-smoke gate belongs in the suite.
"Secret-free" means no real credentials or secret-dependent configuration:
positive signing tests may use public, disposable BIP-340 test scalars in
memory, as the existing suite does. Never copy an operator key into a fixture.

| Case | Required assertion |
|---|---|
| Proactive success, two articles | AUTH tags/id/signature verify under expected identity; matching auth `OK` precedes the first article; exact original article bytes; one auth session serves both |
| Negative auth `OK`, including `auth-required:` / `restricted:` | Correct auth rejection and prefix; zero article writes; other relays continue |
| Auth succeeds, article rejected | Separate successful auth and failed publication; never claim accepted article |
| Malformed input | Reject non-string/empty/control-containing challenges, extra AUTH elements, invalid UTF-8/JSON, malformed/wrong-id `OK`, masked/invalid frames; zero pre-gate articles |
| Oversized / fragmented input | Enforce decoded challenge, frame/reassembly, IPC, and auth-event bounds, including exact-limit/limit+1 cases, without excessive allocation |
| Signer substitution | Wrong identity, URL/port/path, challenge, kind/content/tags, correlation, id, or signature fails before AUTH and EVENT; no arbitrary-event/hash signing request is accepted |
| Freshness and replay | Deterministic fake monotonic/wall clocks cover expiry and skew; duplicate challenge and old response fail; no cross-connection/run response reuse |
| Replacement | One pre-article replacement retires old request/id, tolerates its late reply/OK, and does not extend the deadline; repeated/third/post-article challenge stops the relay; already accepted evidence remains |
| Silence / trickle / blocked signer | Challenge, signing, AUTH-write, auth-OK, partial-message and pipe deadlines all terminate; NOTICE/Ping floods cannot renew them; no pre-gate EVENT |
| Operation-triggered challenge only | A relay waiting for EVENT sees none; explicit challenge-timeout, no fallback |
| Close / cancellation / signer death | Relay-local Close/refusal keeps other relays usable; IPC EOF, malformed session controls, supervisor death and cancellation stop/reap the session; a hung request times out without granting extra signing budget |
| Session ceiling | Fake clocks expire the non-renewing total budget even during ordinary-relay traffic; preserve prior acceptance, mark unfinished work honestly, and bound report/exit teardown |
| Launch/custody | Prove child exec/ready precede key ingestion; child has no key stdin or key-bearing inherited memory/handles; supervisor alone reads the test scalar; no core dump or credential file |
| Mixed relays | Auth success + unauthenticated success → complete; auth rejection/error + accepted plain relay → partial; no acceptance + any auth timeout → incomplete; definitive negatives only → failed |
| Retry | Article timeout resends byte-identical events on the same authenticated connection; no auth resend/reconnect budget expansion; failure never authenticates a non-opted-in relay |
| Compatibility / determinism | Schema-1 no-opt-in goldens and v1 auth-required matrix remain unchanged; repeated offline opt-in plans are byte-identical; old schema/absent-session preflight cannot ignore auth |
| Output hygiene | Capture stdout/stderr/reports and generated files; no test key encoding, raw challenge, auth signature/event, IPC transcript, or raw helper error escapes; malicious reason text is not echoed |

Phase-2 fixtures must cover opt-in schema/version rejection, deterministic
policy serialization, schema-2 auth evidence, and mixed verdicts. A finite
recording relay must assert **absence of EVENT**, not merely a failure report.
Platform subprocess tests must prove actual custody and teardown rather than
inferring them from an interface type.

Phase 2 must implement against this approved boundary, especially custody/exec
ordering, proactive-only compatibility, replacement policy, and schema
negotiation; flag deviations rather than silently changing them. The separately
supplied phase-2 instruction is implementation authority.
Public-relay demand, multi-identity authorization, remote signers, and
reconnect/reauthentication after article delivery remain outside the first slice.

### Phase-2 implementation notes and release evidence boundary

Re-read the complete official NIP-42 and NIP-01 texts at the exact pin above
on 2026-10-01. No upstream-head equivalence or revision change is claimed.

`nostr_auth.zig` owns public policy, correlation, generation/replay limits,
narrow kind-22242 construction and independent verification.
`nostr_auth_ipc.zig` owns anonymous-pipe framing; `nostr_auth_session.zig`
owns custody. The existing publisher and RFC-6455 transport own all relay
work. There are no target-registry or Proof Pack changes.

The private message schema is
[`nostr-auth-ipc-1.schema.json`](schemas/nostr-auth-ipc-1.schema.json).
Every object is closed and every listed field is required, including explicit
nulls in `response`. `ready` carries the fixed public policy; `begin` carries
the fresh run nonce; `sign` carries only correlation plus challenge;
`response` carries correlation and exactly one of event/refusal; `cancel`
and `retire` carry current correlation; `finish` has only the envelope.
Length, UTF-8 byte bounds, nesting, duplicate keys, policy/correlation and
lifecycle checks are enforced in addition to JSON Schema. Complete-frame
deadlines do not renew as partial bytes arrive. IPC transcripts are not outputs.

The **one-replacement** budget permits two auth proofs per permitted relay
while accommodating one connection-local challenge change. An unbounded
replacement sequence would enlarge the signing oracle and permit indefinite
challenge churn. This is not global replay protection, a claim about challenge
randomness, or a way to unsend an article.

macOS launches the resolved same executable with `posix_spawn` and
`CLOEXEC_DEFAULT`, explicitly inheriting only stdout/stderr and two pipe
endpoints, with `/dev/null` stdin and an empty environment. The publisher
execs and reports `ready` before the supervisor reads key stdin. Other
platforms refuse session mode rather than approximate this custody launcher.
Process tests inspect the actual child executable, `/dev/null` stdin and
descriptors before key input. They exercise SIGTERM cancellation and abrupt
supervisor loss during key input, challenge wait, auth-OK wait and article-OK
wait, with bounded child termination and no completed report. This is
process/API separation, not a sandbox.

Real recording-relay tests cover two-article proactive success, negative auth
prefixes, separate article rejection, malformed/oversized challenges and OKs,
masked frames, silence/NOTICE/Ping floods/partial traffic, replay, one replacement
and late OK, third/post-article replacement, mixed relays, unchanged article
retries, absent-session refusal and output hygiene. Focused verifier/policy
tests cover identity/relay/challenge/kind/content/tag substitution, skew,
event ID/signature failures and request budgets. Real pipe-to-publisher-to-relay
tests inject malicious event/correlation substitutions, duplicate/late replies,
signer refusal, hung signer and partial/oversized IPC. Injected transport and
clock tests prove AUTH-write timeout without a teardown flush, and total-ceiling
expiry during ordinary-relay traffic while preserving earlier article
acceptance and skipping unstarted relays. Exact-limit fragmented auth/IPC and
multibyte challenge cases test byte bounds. Offline article event bytes remain
identical across schema negotiation.

The remaining process fault cases now run in the same matrix. A separate,
non-installed Zig test root imports the production CLI/supervisor/publisher
and execs itself through the production launcher. Compile-time seams replace
only executable resolution, pipe-read readiness and selected secp256k1 calls;
an Io wrapper counts stdin operations and injects entropy/write faults.
No production flag, environment override, helper selection or alternate
publisher is added.

- Failed exec, EOF/silent/truncated `ready`, wrong version, unknown fields,
  and mismatched timeout/identity/digest/relay/revision all leave the 65 queued
  stdin bytes untouched. Darwin `FIONREAD` checks the actual kernel queue,
  independently of a zero-stdin-operation counter. Valid sessions assert
  `ready` before their first stdin syscall and observe both core limits zero.
- Forged `begin` and hostile sign/control messages reject extra event/hash
  input, foreign policy/correlation, bad generation/request number, controls
  without a request, wrong/duplicate cancel or retire, signing after retirement,
  unknown controls, extra finish fields, EOF and truncated frames. They emit
  no completed report and open no relay socket. Signing-call counts distinguish
  immediate refusal from rejection after one valid proof.
- Seed entropy, context creation/randomization and keypair failures stop before
  `begin`. One-shot aux entropy, signing and self-verification failures remain
  disabled on the next opted-in relay even though the injected primitive can
  recover; a plain relay still receives both unchanged articles. The recording
  auth relays receive zero AUTH/EVENT. All handled exits destroy their contexts.
- Real anonymous pipes are filled until kernel `POLLOUT` is absent during
  `begin`, sign-request and response writes. Their complete-frame deadlines
  terminate. SIGTERM cancellation, supervisor SIGKILL and publisher SIGKILL
  during these waits and an injected pending socket write terminate both
  processes within the teardown bound, with no AUTH/EVENT or completed report.
  Socket-write cancellation uses the actual transport's Io path with an
  injected pending write; native socket backpressure/deadline coverage remains
  in the standing WebSocket test. SIGKILL discards the address space, not a claim
  that cleanup handlers ran.
- Invalid encoding, invalid secret scalar, wrong identity and overlong key
  input refuse before `begin` with content exit 1, no key echo and no sockets.
  Relay Close during challenge/auth-OK remains local: zero article writes
  there, while a plain relay still publishes.

Draft 2020-12 meta-schema checks pass for all three changed/new schemas.
External validation covers the profile fixture, the actual emitted schema-2
general declaration, schema-1 rejection, all eight IPC forms and omission/
unknown-field rejection. The scoped implementation and fault-injection evidence
are complete on macOS; the PR remains draft and unmerged for human review.
Linux is cross-compiled, not session-tested, and refuses the custody launcher.
No public-relay interoperability, sandbox or perfect-memory-erasure claim is
made. These limits do not weaken the approved boundary.
The default Debug standing gates and all 28 NIP-42-filtered native ReleaseSafe
cases pass. The optional full ReleaseSafe Nostr suite exceeded 300 seconds
in the existing high-volume write-fuzz case; that whole optimized suite is
not claimed as passed.

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
