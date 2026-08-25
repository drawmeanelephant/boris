# Standard.site target contract

**Status:** normative conceptual + artifact contract
**Version:** 1 (target registry, deterministic offline projection, verification
surfaces, one-shot publish command, persistent sessions)

Standard.site is Boris's second verified publication target. Publishing to the
Atmosphere is an atproto write: a **publication record** in
`site.standard.publication` naming the site, and one **document record** per
eligible page in `site.standard.document`, each linking the other. This
contract fixes the deterministic offline projection (the plan) and the
web-facing verification surfaces (head links + well-known file) that make the
write verifiable. It does **not** define live interop; persistent sessions and
the write command are covered here and in
[`atproto-sessions.md`](atproto-sessions.md), and live interop is a separate,
follow-on contract.

## Target identity

| Constant | Value |
|---|---|
| `publication.target` | `"standard-site"` |
| Publication collection | `site.standard.publication` |
| Document collection | `site.standard.document` |
| Publication rkey | `self` (fixed) |
| Well-known path | `.well-known/site.standard.publication` |

The target name is part of the closed target registry
([`publication-platforms.md`](publication-platforms.md)): existing
`"github-pages"` profiles and plans parse byte-identically, and unknown names
fail closed in the profile parser.

## Profile shape

The profile parser accepts a `publication` block with `target:
"standard-site"` plus the standard `base_url` / `origin` / `base_path`
location values and these Standard.site fields:

| Field | Meaning | Constraint |
|---|---|---|
| `did` | The publishing account | valid AT Protocol DID syntax |
| `name` | Site name in the publication record | non-empty, ≤ 5000 bytes |
| `description` | Optional site description | ≤ 30000 bytes |
| `show_in_discover` | `preferences.showInDiscover` hint | boolean |
| `include` / `exclude` | Page filters | glob patterns; filters apply to entity ids |
| `prune` | Delete records absent from the projection | boolean (write-command input) |
| `pds` | Optional pin of the write PDS origin | omitted → publish binds to the PDS discovered from the DID document; if set, HTTPS origin that must match that discovery after parse |

The location invariant from
[`publication-platforms.md`](publication-platforms.md) holds: `base_url` must
equal `origin` plus `base_path`, enforced by the profile parser before any
projection runs. Unlike GitHub Pages, a non-empty base path is **legal** on
Standard.site; the verification plan then reports the domain-root well-known
limitation honestly instead of guessing a URL.

Fixture: [`fixtures/publication-plan/standard-site/profile.json`](fixtures/publication-plan/standard-site/profile.json).

## Deterministic projection (the plan)

`standard_site.project` consumes the profile configuration and the compiled
page set and emits a deterministic projection: one planned publication and a
planned document per **eligible** page, plus recorded exclusions. The plan
artifact (`boris-standard-site-plan`, schema v1) has fixed JSON key order, LF
endings, and no timestamps or host data; two identical inputs produce
byte-identical plans.

### Eligibility

A page becomes a planned document only when **all** of:

1. Status is `published` or `archived` (drafts are excluded with reason
   `draft`);
2. `published_at` is present and normalizes to the atproto datetime form
   `YYYY-MM-DDTHH:MM:SS.000Z` (reason `missing_date` otherwise);
3. The entity id passes the configured include/exclude filters (reason
   `filtered`);
4. The output path is a safe relative `*.html` path (no leading slash,
   backslash, or `..`).

Every exclusion is recorded with its entity id, reason (`draft`, `missing_date`,
`filtered`, `unsupported`), and a human-readable detail. Rkey collisions across
the planned collection fail closed.

### Document rkeys

The rkey is a reversible encoding of the entity id: alphanumerics, `-`, and `.`
pass through; `/` becomes `:`; any other byte becomes `~HH` hex. If the encoded
value would exceed 512 bytes (or is empty), it falls back to the lowercase
hex SHA-256 digest with a `~~` prefix, which is not reversible but is
deterministic. `~` is a safe rkey character under atproto's rkey grammar.

### Payloads

`site.standard.publication` payload (fixed key order):

```json
{"url":"…","name":"…","description":"…","preferences":{"showInDiscover":true}}
```

`site.standard.document` payload (fixed key order): `site` (the publication
AT-URI), `title`, `publishedAt`, `path`, then optional `description`, `tags`,
and `textContent`. `textContent` is populated from the deterministic semantic
plain-text projection when it renders cleanly and stays within bounds; it is
omitted (never substituted with raw source or HTML) otherwise — see
[`plain-text-projection.md`](plain-text-projection.md). Record size limits:
256 KiB per record, 4096 pages maximum.

## Verification surfaces

The compiler emits two verification surfaces from the committed projection;
both are consumed by indexers and by the reconciliation contract.

### Head document links

Each eligible page's HTML carries, in the compiler-owned `{{head}}` slot only:

```html
<link rel="site.standard.document" href="at://…">
<link rel="site.standard.publication" href="at://…">
```

`{{head}}` is a closed slot: layouts opt in by placing it in `<head>`, and the
document AT-URI can never leak into the body. Ineligible pages emit an empty
slot, so nothing silently claims document verification. Layouts that omit
`{{head}}` produce the `EVERIFICATIONHEAD` warning
([`diagnostics.md`](diagnostics.md)) so absence is never silent. The `boris
init` reference layout includes the slot.

### Well-known publication record

For domain-root sites (`base_path` empty), the build writes the exact
publication AT-URI bytes to `.well-known/site.standard.publication` in the
committed target. For base-path sites, the build cannot serve the domain-root
well-known path, so it **does not** emit a decoy: it records the exact required
bytes as a sideband artifact (`_boris/proof/standard-site-well-known.txt`) and
reports the limitation.

### Verification report

`_boris/proof/standard-site.json` (`boris-standard-site-verification`, schema
v1) is the post-commit evidence artifact. It records, per document,
`entity_id`, `at_uri`, and a status of `emitted` or `not_verified`, plus a
`well_known` block with `status` (`emitted` or `limited`), the project path of
the emitted file, the exact public URL an indexer probes, and the sideband
path. The report is deterministic and is produced on every production render
path, so the HTML and the evidence can never disagree.

## Relationship to the write command

The plan is the **intended** state; the verification surfaces make it
observable. The one-shot publish path reconciles the plan against observed
record state and writes evidence with intended-vs-observed claims per
[`standard-site-reconciliation.md`](standard-site-reconciliation.md).

### `boris standard-site plan`

The pure-offline projection surface. `boris standard-site plan --profile PATH
[--out PATH]` compiles the content tree, renders the deterministic
`boris-standard-site-plan` (schema v1) — publication + document records with
each document's full `textContent` and its digest, exclusions, and
verification surfaces — and writes it to `--out` or stdout. The plan is
self-contained for review: every document entry carries the actual plain-text
projection alongside `text_content_sha256`, so an operator can read what will
be indexed without a second artifact. It performs no discovery, OAuth, transport, or mutation, so
an operator can inspect exactly what `publish` would do before any network
authority is exercised. The emitted bytes are byte-identical to the plan
`publish` validates and publishes, so the same artifact can be committed and
later passed to `publish --plan` for the drift gate.

### `boris standard-site records`

The full-payload offline dump. `boris standard-site records --profile PATH
[--out PATH]` runs the identical compile + projection pipeline as
`plan`/`publish` and renders the complete, canonical record bodies — the
publication plus every eligible document, with each document's full
`textContent` embedded — as `boris-standard-site-records` (schema v1). Unlike
the plan, which summarizes each record, this artifact contains the exact
canonical JSON `publish` would PUT (every field of the complete record body),
so an operator can review every byte without any discovery, OAuth, transport,
or mutation. Fixed key order, LF endings, no timestamps or host data; identical
inputs produce byte-identical output.

### `boris standard-site verify`

The offline post-build cross-check. `boris standard-site verify --profile
PATH [--dist DIR] [--out PATH]` renders the projection + verification
surfaces, then compares the already-emitted artifacts in the built output
directory against them byte-for-byte: each eligible page's
`<link rel="site.standard.document">` head link in its HTML, and the well-known
file (root/custom-domain sites) or its `_boris/proof/standard-site-well-known.txt`
sideband (base-path deployments). Any missing or mismatched surface fails the
check with exit code 8 and zero writes; the result is a deterministic
`boris-standard-site-verify` (schema v1) artifact carrying `overall_passed`,
the well-known status (`match`/`mismatch`/`missing`), and per-document status
(`verified`/`mismatch`/`missing`). It performs no discovery, OAuth, transport,
clock, or mutation — it reads only the local `--dist` tree (default `dist`).

### `boris standard-site publish`

The explicit, never-implicit network family. `boris standard-site publish
--profile PATH` resolves the configured DID, verifies the DID document's PDS
against the profile-bound PDS, obtains an authorized session, and invokes the
reconciler. Session acquisition prefers the persistent store
([`atproto-sessions.md`](atproto-sessions.md)): a stored unexpired session is
reused without the browser, an expired one is refreshed in place, and only when
nothing is stored does publish run the one-shot interactive OAuth flow
(browser, PAR, callback, token exchange) and persist the result. The
reconciler re-checks the session's DID, PDS, and authorization server against
fresh discovery before any write. The committed plan is loaded when `--plan`
is given and must match the freshly rendered plan byte-for-byte before any
network mutation; `--prune` is the explicit prune authority (ANDed with the
profile `prune` flag); evidence goes to `--out` or stdout; `--source-commit`
records the source revision in the evidence bindings. Exit codes 4–8 classify
denial, timeout, compatibility, partial-publication, and verification failures,
and exit code 9 covers the session layer
([`diagnostics.md`](diagnostics.md)). No credential file, environment token,
cookie jar, shell command, or ambient proxy is introduced, and no secret ever
appears in command output or evidence. Plain-text projection is a separate,
optional, non-blocking lane.

### Session management

`boris standard-site login --did DID` authorizes the account in the browser
and persists the DPoP-bound session under the user-scoped session root;
`boris standard-site sessions` lists each stored DID with its credential
flavor (`oauth` or `app-password`) and PDS origin; `boris standard-site logout
(--did DID | --handle HANDLE)` securely erases one session. All three honor `--session-root` as an
explicit root override. See [`atproto-sessions.md`](atproto-sessions.md) for
the storage, refresh, rotation-safety, recovery, and threat model.

### Live interoperability smoke

`boris standard-site smoke --did DID` is the manual, opt-in gate that proves
the full path against a real test identity: discover, authorize, write a
uniquely namespaced publication + document pair, read both back and verify
identity/value/CID, optionally check the served verification surface and
observe an indexer (non-normative), then delete exactly the two created rkeys.
It emits a deterministic, secret-free `boris-live-smoke-result` artifact and is
excluded from `zig build test` and every CI path. See
[`atproto-live-smoke.md`](atproto-live-smoke.md).
