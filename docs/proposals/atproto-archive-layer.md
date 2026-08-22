# ATProto archive layer — design sketch

**Status:** design sketch; no implementation

This sketch describes a content-addressed, blob-backed ATProto archive sidecar
for Boris sites. It does not change the primary `dist/` output, the existing
`site.standard.document` record schema, or any current publish path.

## Current boundary

Standard.site publish today writes two record types inline:

- `site.standard.publication` — site identity, location, metadata
- `site.standard.document` — per-page records with `text_content`, `title`,
  `path`, `published_at`, etc.

Every document record carries its full payload in the record JSON, bounded by
`max_record_bytes` (256 KiB). Large pages or pages with rich content approach
or exceed that limit. Assets (CSS, images, JavaScript) are not published to
ATProto at all — they live only in `dist/` or the target deploy surface.

The existing SHA-256 digest infrastructure (`standard_site.zig:payload_sha256`,
`artifact_inventory.zig:sha256`, `cache.zig`) already computes per-artifact
digests during compilation, but these digests are not currently exposed to the
ATProto publish path.

## Proposed model

Add a **site archive projection** that uploads the full compiled `dist/` tree
as content-addressed blobs, then writes one or more manifest records binding the
blob CIDs to their original file paths (sharded across records when the
manifest exceeds the 256 KiB `putRecord` limit — see **Manifest sharding and
rkey design** below). This runs as an **additional
publication step** (`boris standard-site publish --archive`) that operates
alongside the existing inline document records, not replacing them.

### Archive structure

```
dist/                        ← canonical output, unchanged
  index.html
  guides/intro.html
  assets/main.css
  assets/logo.png

ATProto (new):
  blob: zb2rhX8...eC5G       ← index.html bytes
  blob: zb2rhY9...fD6H       ← guides/intro.html bytes
  blob: zb2rhZ0...aE7I       ← assets/main.css bytes
  blob: zb2rhA1...bF8J       ← assets/logo.png bytes

  site.standard.archive       ← manifest record
  {
    "site": "at://did:plc:.../site.standard.publication/self",
    "publishedAt": "2026-08-22T14:30:00.000Z",
    "files": [
      {
        "path": "index.html",
        "blob": { "$link": "bafyreihwn3gfvnopsh4a6dmn2d3b7k5wqj2jqbzj6jydhpm5yfjjj7qbx4" },
        "mimeType": "text/html",
        "size": 12345,
        "sha256": "a414d9d9715c46e455b688c126cebb8f628bdb72155e0524654746019898486d"
      },
      ...
    ]
  }
```

### Key properties

1. **Content-addressed integrity.** Each blob's CID is a hash of its content,
   so the manifest is a cryptographic manifest of the exact published site.
   Tampering at any layer is detectable.

2. **Portability.** A consumer that resolves the manifest record and fetches
   all blobs has a byte-for-byte replica of the compiled site — independent of
   where the site was deployed, whether the deploy surface is still live, or
   whether the original compiler repo still exists.

3. **Immutable snapshots.** Each publish writes a new manifest record (with a
   new rkey, e.g. `archive-2026-08-22T143000Z-a3f8`), so the archive
   preserves a history of every published version. Old blobs remain referenced
   by old manifest records and are not garbage-collected. The rkey includes a
   random or monotonic suffix (see **Manifest sharding and rkey design** below)
   to prevent collisions when two publishes land within the same second.

4. **Bypasses the 256 KiB record limit.** Document records with large
   `text_content` can approach the `putRecord` limit; blob-backed files have
   no per-blob limit below the PDS default (300 MiB self-hosted, ~50 MiB
   hosted). A single archive can hold a complete site regardless of individual
   page sizes.

5. **Complementary, not replacement.** The existing document records remain
   the primary indexable, searchable surface. The archive layer is the
   backup-and-portability sidecar.

### Scope decisions

| Concern | Decision |
| --- | --- |
| Primary serving | `dist/` (Pages, local server, CDN) — archive is not a web server |
| Indexing | Document records via `getRecord` — archive is cold storage |
| Record schema | New collection `site.standard.archive` (sharded projection; see below) |
| Blob lifecycle | Manifest record references every blob → GC holds them |
| Upload ordering | All blobs uploaded before manifest record to beat GC window |
| Incremental publish | Opt-in `--archive` flag; the smoke test stays blob-free |
| Deduplication | Same bytes → same CID → single upload; record-reuse detection by CID comparison before `uploadBlob` |

### Manifest sharding and rkey design

**Problem 1 — rkey collisions.** A pure timestamp rkey like
`archive-2026-08-22T143000Z` collides when two publishes run within the same
second. **Solution:** Use a compound rkey
`archive-YYYY-MM-DDTHHMMSSZ-<suffix>` where `<suffix>` is a 4-character random
hex string generated at publish time. The timestamp gives human-readable
ordering; the random suffix makes the key collision-resistant without requiring
state. A UUID-based rkey is also valid but less readable. The suffix is not
secret — it only needs to be unique per DID.

**Problem 2 — manifest exceeds the 256 KiB `putRecord` limit.** Each file
entry in the manifest (path, CID link, mime type, size, sha256) is roughly
300–400 bytes of JSON. A site with 800+ files can exceed the record limit.
**Solution:** Shard the manifest across multiple records when the assembled
payload would exceed `max_record_bytes` (256 KiB). The scheme is:

1. Compute the full manifest JSON.
2. If `len(manifest) ≤ 256 KiB`, write it as a single record (common case for
   small-to-medium sites).
3. If `len(manifest) > 256 KiB`, split the `files` array into chunks of
   ≤ 256 KiB of JSON each, and write:
   - A **root record** (rkey `archive-<ts>-<suffix>`) containing `site`,
     `publishedAt`, `totalFiles`, `totalChunks`, `sha256` (hash of the full
     manifest for integrity), and an ordered list of `{ rkey, chunkIndex }`
     entries pointing to the chunk records.
   - **Chunk records** (rkeys `archive-<ts>-<suffix>-c0`, `-c1`, …) each
     containing `{ chunkIndex, files: [...] }`.
4. A consumer reconstructs the full manifest by reading the root, then each
   chunk in order, and verifying the concatenated `files` array matches the
   root's `sha256`.

The sharding is transparent to the caller: the projection decides at write
time whether to produce one record or N+1 records. The `--archive` CLI flag
and the implementation card remain unchanged; only the manifest write path
needs the split logic.

### Honest gaps

1. **No `uploadBlob` in `atproto_xrpc.zig` yet.** The XRPC client currently
   speaks `getRecord` / `putRecord` / `deleteRecord` only. Adding `uploadBlob`
   requires a new XRPC method in the client (binary body, multipart or raw
   stream), plus DPoP nonce handling for blob endpoints.

2. **No CID-from-bytes computation in the client.** The blob CID type
   (typically CIDv1 + raw codec + SHA-256 multihash) is not computed by Boris
   today. The PDS returns the CID after upload; the manifest record stores
   whatever CID the PDS returns. For deduplication (skip upload if same bytes
   already exist), Boris would need to compute CIDs itself or maintain a
   local CID→path map from prior manifests.

3. **Hosted PDS blob limit is ~50 MiB.** A typical compiled site (50+ pages,
   with images) can exceed that. The self-hosted default is 300 MiB. This
   pushes the archive feature toward self-hosted PDS use, which is the
   Standard.site operator profile anyway.

4. **Serving from PDS is slow.** `getBlob` is direct PDS access, not a CDN.
   The archive is designed for cold storage and integrity, not for browsing.
   A consumer that wants to serve an archived site should pull the blobs
   once and front them with a CDN or static file server.

5. **Blob GC window.** The protocol requires a record to reference a blob
   within a short, undefined window after upload. The tool must upload all
   blobs first, then immediately write the manifest record(s) — pause or
   network delay between the last blob upload and the manifest write risks GC.
   For sharded manifests, all chunks must be written in rapid succession
   after the final blob upload.

## Relationship to existing infrastructure

Boris already carries the digest pieces; the archive layer connects them to
the ATProto wire:

- `cache.zig` — SHA-256 of bytes (deterministic, length-delimited)
- `artifact_inventory.zig` — filesystem path → sha256 map for compiled outputs
- `standard_site.zig` — `payload_sha256` on every document record
- `atproto_xrpc.zig` — typed `putRecord` / `getRecord` / `deleteRecord` client
  bound to session DID and PDS origin

The archive layer would add:

- A new `uploadBlob` XRPC method to `SessionClient` (binary body, DPoP nonce)
- A new `PlannedArchive` projection type in `standard_site.zig` (or a sibling
  module `standard_site_archive.zig`) that reads the artifact inventory and
  produces the blob upload sequence + manifest record
- A new collection constant `site.standard.archive`
- A new CLI flag `--archive` under `boris standard-site publish`

## Why this is not wired yet

1. No `uploadBlob` client.
2. No blob upload in the live smoke path (needs a new standalone test).
3. The artifact inventory records every `dist/` file with exact `sha256`
   values, but the archive projection that maps those to CIDs and blob uploads
   doesn't exist.
4. CID computation for deduplication is a new dependency shape (multihash,
   codec tables) that should be evaluated against a Zig-native path or the
   `zat` library.

## Recommended implementation cards

1. `fix/standard-site-upload-blob-client`
   - add `uploadBlob` to `SessionClient` in `atproto_xrpc.zig`
   - binary body, correct content-type, DPoP nonce retry
   - accept and return the PDS-issued blob metadata (CID, mime, size)
   - test with a mock PDS

2. `fix/standard-site-archive-projection`
   - new module `standard_site_archive.zig`
   - reads `artifact_inventory` records, uploads each blob, deduplicates by
     CID, writes manifest record
   - collection: `site.standard.archive`
   - preserves existing document records unchanged

3. `fix/standard-site-archive-cli`
   - `boris standard-site publish --archive` flag
   - smoke test stays blob-free
   - separate evidence/report artifact

## Explicitly unsupported in the first implementation

- Blob serving or web browsing from the PDS
- Incremental/delta archives (always full snapshot)
- Partial sites or per-section archives
- CID computation before upload (rely on PDS-returned CID)
- Asset transformation, compression, or resizing during upload
- Replacing the inline document records with blob references
- Archive as primary publication target (it's a sidecar)

## Verification bar for a future PR

- `zig build test` passes (existing suite) plus new archive-specific tests
- `boris standard-site publish --archive` uploads all blobs, writes manifest,
  returns exit 0
- `git diff --check` clean
- Live smoke (`boris standard-site smoke`) unchanged — still exit 0, no blob
  uploads
- Manifest record readback via `getRecord` returns exact CID and sha256 per file