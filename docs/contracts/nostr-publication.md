# Nostr publication plan (NIP-23, offline slice)

**Status:** normative offline-plan contract. `boris nostr plan --profile PATH`
reads one explicitly selected local publication profile, selects the
allowlisted pages that are eligible as NIP-23 long-form articles, derives the
publication-safe Markdown and tag set each event would carry, and writes one
canonical JSON declaration to stdout. It holds no key, produces no signature,
opens no socket, and publishes nothing.

The plan is a report about a website Boris already knows how to build. It
describes what a later signing slice would sign and what a later publish slice
would send, in enough detail that a maintainer can review both before either
exists. Every fact in the plan is derived from committed content and the
selected profile, so the same inputs always produce the same bytes.

## Scope

This slice is an offline, deterministic planner and nothing else. Its output is
a declaration; a successful run means only that Boris has computed a reviewable
publication plan.

Explicit non-goals:

- No secret key is read, held, derived, generated, or requested. There is no
  key file, no key flag, no key environment variable, and no key prompt.
- No signature. The NIP-01 `sig` field is absent, and so is the event `id`:
  both are functions of `created_at` and the signing key, neither of which
  exists here.
- No `created_at`. Wall-clock time is a signing-time input, not a plan input.
- No relay connection, handshake, subscription, `EVENT` message, or `OK`
  response. Configured relay URLs are strings to normalize and sort, never
  endpoints to probe.
- No NIP-42 relay authentication and no NIP-09 deletion request.
- No Nostr client, relay, key manager, or wallet is implemented or vendored.

A bare `boris build` never touches the network. The Nostr surface is a separate
opt-in command over the same content, so nothing about it can move bytes into a
build. A failed Nostr operation — an ineligible article, an unportable
paragraph, an unnormalizable relay URL, a refused plan — cannot invalidate a
built website. The website is the product; the plan is a report about it.

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

`plan` is the only `nostr` subcommand in this slice. Any other subcommand
spelling — including any word that suggests signing, sending, or deleting — is
a usage error, not a stub, because no such capability exists to route to.

| Code | Meaning |
|-----:|---------|
| `0` | A complete plan was written to stdout |
| `1` | Content failure: an allowlisted article is ineligible, or its publication-safe Markdown is not portable |
| `2` | Usage or configuration failure: unknown subcommand or flag, missing `--profile`, invalid profile, invalid `nostr` section, or an enabled section with no publication location |
| `3` | I/O or system failure, including a stdout write failure |

Exit `1` and exit `2` are kept distinct deliberately. Exit `1` means an author
must change a page; exit `2` means an operator must change the profile. Nothing
is written to stdout on either.

## Profile configuration

The Nostr surface is configured by one closed `nostr` section in the selected
publication profile. `boris plan --profile` emits it as a `"nostr"` object only
when it is configured, so an unconfigured profile keeps its current plan bytes
exactly.

| Key | Meaning |
|-----|---------|
| `enabled` | Whether the Nostr surface is configured for this workspace |
| `pubkey` | The expected author public key, as 64 lowercase hex characters (NIP-01 hex form, not `npub`) |
| `articles` | Exact entity-id allowlist; canonically sorted and deduped |
| `relays` | Relay endpoints, each normalized to `wss://` form, canonically sorted and deduped |
| `timeout_ms` | Declared transport timeout, reserved for a later publish slice |
| `retries` | Declared transport retry count, reserved for a later publish slice |

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
identity. This slice never reads them for behavior because it opens no
connection; they are carried so an operator can review and version the
transport settings a later slice will use.

`pubkey` is the **expected author public key**. It is public data whose only
purpose is stating which author's address the planned article belongs to, and
whose only enforcement is that a later signing slice must refuse to sign with a
key that does not match it. It is not a credential, and it does not become one
by being configured.

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
| `image` | — | omitted in v1: Boris owns no document-image fact, and this slice will not promote a body image or a theme asset into article metadata |
| `created_at` | — | deferred: supplied at signing, never planned |
| `pubkey` | Profile `nostr.pubkey`, as the expected author | planned as expectation; the signer supplies the real value |
| `id`, `sig` | — | deferred: both are functions of `created_at` and the signing key |

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

## Diagnostics

Three codes are emitted by this slice, all at `error` severity; see the
[diagnostics contract](diagnostics.md) for the shared object, text form, and
ordering.

| Code | Phase | Exit |
|------|-------|-----:|
| `ENOSTRELIGIBILITY` | Eligibility selection: an allowlisted page cannot be published as NIP-23, its entity id is absent from the page graph, or an authored tag is not a valid `t` topic | `1` |
| `ENOSTRMARKDOWN` | Publication-safe Markdown validation: the view carries a fail-closed defect, or a doc-link, wiki-link, include, or content-local image does not resolve | `1` |
| `ENOSTRTIME` | `published_at` derivation: the authored UTC `published_at` does not convert to a Unix second count | `1` |
| `ENOSTRPLAN` | Plan assembly against a corpus that changed under the run: a selected source no longer parses after the graph validated | `1` |

`ENOSTRRELAY` is registered but **not emitted here**. Relay configuration is
refused earlier and harder, by the strict profile parser, as an invalid `nostr`
section (exit `2`) — before any content is read. The code is reserved for the
publish slice, where a relay is a live endpoint that can reject, time out, or
demand authentication, and where a per-relay outcome needs a per-relay
diagnostic.

Configuration failures do not use a diagnostic code at all. A missing
`--profile`, an invalid profile, a malformed `nostr` section, a disabled
section, an invalid expected-author `pubkey`, and an enabled section with no
publication location are all usage errors reported on stderr with exit `2`,
because none of them is a statement about content.

`ENOSTRSIGN` is deliberately **not** part of this slice. It belongs to the
later signing slice, and reserving a code for a capability that does not exist
would imply the capability is coming with a shape already decided.
