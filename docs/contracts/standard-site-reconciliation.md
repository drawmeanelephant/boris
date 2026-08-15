# Standard.site reconciliation and evidence contract

**Status:** normative publish-time contract
**Version:** 1 (reconcile against the committed plan, intended-vs-observed
evidence; CLI wired via `boris standard-site publish`)

This contract defines how a committed Standard.site plan is reconciled against
the authenticated PDS and how the publish evidence is emitted. It is the
publish-side counterpart to
[`standard-site.md`](standard-site.md): the plan is the intended state, this
contract is the honest observation of what actually happened.

## Authority and transaction boundary

The reconciler consumes four things and nothing else:

1. The committed offline plan (`boris-standard-site-plan`, rendered by the
   projection) and its SHA-256 digest;
2. The in-memory projection (intended payloads for the publication and each
   document, plus recorded exclusions);
3. An authorized XRPC session bound to the account PDS;
4. An explicit prune authority (off by default).

Before any mutation it verifies **all** of the following; any mismatch fails
closed with zero writes:

- the plan digest equals the committed plan bytes;
- the session DID equals the plan `inputs.did`;
- the session PDS origin equals the plan `inputs.pds_origin`;
- every collection name is the Standard.site constant
  (`site.standard.publication` / `site.standard.document`);
- every rkey matches the plan (`self` for the publication, the plan's document
  rkeys otherwise).

A failed publication cannot modify source content or invalidate the
already-built static site: the reconciler writes only through
`com.atproto.repo.putRecord` / `deleteRecord` on the PDS and never touches the
content tree or the committed target.

## Per-record classification

Each planned record is fetched first (`getRecord`) and classified against the
intended payload by **canonical value comparison** — the remote record `value`
is deep-compared to the intended payload JSON, key-order-insensitive. The
reconciler never hand-rolls DAG-CBOR CIDs and never infers remote state from a
local digest.

| Intended state | Remote observation | Operation | Verification |
|---|---|---|---|
| Record planned | Not found | `create` (`putRecord`) | `write_response` |
| Record planned | Found, identical | none (zero writes) | `observed` |
| Record planned | Found, differs | `update` (`putRecord` with `swapRecord` = observed CID) | `write_response` |
| Record planned | Write failed | confirming `getRecord` | see below |
| Page excluded, record exists remotely | Found | orphan: skip, or delete under explicit prune | `observed` / `write_response` |

### Ambiguous writes

An ambiguous write failure (timeout or transport error) is **never** reported
as success from the failed response alone. The reconciler performs a confirming
read; only if the intended value is now present does it record the outcome with
`verification: confirming_read`. If the confirming read shows nothing or a
different value, the record is `failed` with the exact error name. A conflict
(swap mismatch) therefore never overwrites the remote value.

### Orphans and prune

A remote record whose page is excluded from the plan (draft, missing date,
filtered, or unsupported) is an **orphan**. Without explicit prune authority it
is skipped and recorded as `skipped_orphan` — a missing local page never
deletes a remote record. With explicit prune (both the plan's `prune` flag and
the publish invocation must opt in), the orphan is deleted with
`swapRecord` set to the observed CID so a concurrent writer cannot silently
lose data.

### Partial failure

Independent per-record failures do not abort the whole run: a rejected
document does not block its siblings, and the reconciler continues. Any failure
makes the overall result `failed` (nonzero); the evidence still records every
per-record outcome so the operator can see exactly what landed.

## Evidence artifact

Format `boris-standard-site-evidence`, schema v1. The artifact binds:

- **identity** — non-secret DID and PDS origin;
- **bindings** — source commit, Boris pin, Oliver pin, and the offline plan
  digest;
- **records** — one entry per intended record (publication and documents) and
  per handled orphan, each with the AT-URI, rkey, `intent` (from the plan),
  `outcome` (observed), `verification`, intended payload SHA-256, observed CID
  (when present), observation time, and the exact failure (when failed).

Intended state and observed remote state are **separate claims**: `intent`
comes from the committed plan, while `outcome` / `observed_cid` /
`verification` describe what the PDS actually showed. The artifact contains no
access token, refresh token, DPoP private material, authorization code, raw
proof, or secret response header, and it renders deterministically (fixed key
order, LF endings, injected observation time only).

Normal builds emit no network evidence: reconciliation runs only on an explicit
publish invocation.

## Non-goals (unchanged from the issue)

Interactive browser or CLI orchestration, persistent OAuth sessions or refresh,
implicit pruning, rebuilding the static site during network mutation, indexer
verification, remote deployment, blob upload, and private records are all out
of scope for this contract.
