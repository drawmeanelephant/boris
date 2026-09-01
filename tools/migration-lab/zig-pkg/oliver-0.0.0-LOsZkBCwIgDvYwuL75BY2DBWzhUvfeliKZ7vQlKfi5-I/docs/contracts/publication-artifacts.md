# Publication artifact inventory (schema v1)

**Status:** normative first runtime-evidence slice for one HTML target.

The publication artifact inventory records the Boris-owned payload files that
the HTML target transaction is about to commit. It is a declared inventory of
committed bytes, not a proof pack, quality score, check report, or deployment
manifest.

## Output and scope

Each selected HTML target publishes:

```
{target}/_boris/proof/artifacts.json
```

The inventory covers the current HTML transaction's:

- HTML pages;
- theme assets;
- content-local page assets;
- rendered search index; and
- XML sitemap when sitemap publication is selected.

When a hosted publication identity is configured, these generated HTML and
sitemap bytes pass the pre-commit publication-location gate as part of the
same transaction. The inventory records exact local target bytes; it does not
add a deployment URL field or claim that the deployed host served them.

The shared record vocabulary also reserves `rss` and `llms` kinds for a future
coordinated HTML publication transaction. The current standalone `--rss` and
`--llms` commands have separate publication transactions and do not write this
HTML-target inventory. They remain separate projections rather than being
silently inferred from their standalone outputs.

IR, RAG, and Context Bundle outputs are not included in this first inventory.
The current coordinator does not commit them in the same target transaction;
their projection contracts remain independent.

The inventory file does not inventory itself, nor any later proof-pack
envelope, check, claim, limitation, or touch-map file. A later envelope may
inventory evidence files as a separately versioned artifact.
The target-local checks path, `_boris/proof/checks.json`, is reserved for the
separate publication-checks report and is rejected as a producer-owned path.

## Format

The root object is `boris-publication-artifacts`, schema version `1`, with the
fixed key order shown here:

```json
{
  "format": "boris-publication-artifacts",
  "schema_version": 1,
  "target": "public",
  "artifacts": [
    {
      "path": "guides/install.html",
      "kind": "html-page",
      "producer": "html-render",
      "required": true,
      "status": "committed",
      "bytes": 4567,
      "sha256": "lowercase-64-hex-digest",
      "format_version": null
    }
  ]
}
```

The published schema is [`publication-artifacts-1.schema.json`](https://github.com/drawmeanelephant/oliver/blob/main/docs/contracts/schemas/publication-artifacts-1.schema.json).
Every first-slice record has these fields, in this order:

| Field | Meaning |
|---|---|
| `path` | Target-relative path using `/`; never an absolute or staging path. |
| `kind` | Closed stable kind name such as `html-page`, `theme-asset`, `content-asset`, `rendered-search`, `sitemap`, `rss`, or `llms`. |
| `producer` | Plain stable producing phase name, not arbitrary prose. |
| `required` | Whether the selected publication requires this payload. |
| `status` | First-slice records are `committed`; the vocabulary also reserves `omitted-by-plan` and `not-applicable` for later plan-aware inventories. |
| `bytes` | Exact byte length of the payload bytes read for the transaction. |
| `sha256` | Lowercase hexadecimal SHA-256 of those exact bytes. |
| `format_version` | A known producer format/schema version, or explicit `null` when the payload has no such version. |

Records sort by target-relative `path` using bytewise ordering, then by `kind`
when a future producer vocabulary permits multiple records at one path.
Duplicate paths are rejected. Object key order, array order, path separators,
and lowercase digest encoding are deterministic.

## Authoritative collection

The inventory is assembled from producer facts already held by the compiler:

| Payload | Authoritative source | Byte source | Producer |
|---|---|---|---|
| HTML page | PageDb `output_path` | staged page, or live target for a valid incremental cache hit | `html-render` |
| Theme asset | loaded theme asset inventory | newly staged asset | `theme-assets` |
| Content-local asset | loaded sibling-asset inventory | newly staged asset | `content-assets` |
| Rendered search | `search_index.output_path` | newly staged search file | `rendered-search` |
| Sitemap | selected sitemap path | newly staged sitemap file | `sitemap` |

The collector does not crawl the target directory, parse human reports, infer
artifacts from directory names, or claim unrelated deployment-owned files.
Generated projections and copied assets are stage-only inputs: a stale live
file cannot satisfy a new selected record. Cached HTML is the deliberate
exception because incremental publication reuses the exact live page bytes.

Removed pages and stale assets are absent because the inventory is built from
the current PageDb and current producer inventories, not from the previous
target tree.

## Transaction and failure behavior

The inventory is collected after selected producers have staged their bytes and
before `publishStageTree` commits the target. `artifacts.json` is itself
atomically staged under the target-owned `_boris/proof/` namespace and then
committed last by the same target transaction, after every other staged payload
replacement succeeds. Therefore:

- a render, asset, search, sitemap, inventory-write, or target-commit failure
  does not replace a prior valid inventory;
- a successful incremental build emits the complete current inventory,
  including cached pages, rather than only dirty records;
- a successful rebuild omits removed pages and stale assets;
- sequential, parallel, clean, and no-change incremental builds use the same
  producer paths and exact bytes, so their inventories are byte-identical when
  payload bytes are identical; and
- the inventory is deferred until the final staged payload replacement, but
  the underlying HTML publisher is per-file rather than a whole-tree rollback
  journal. A mid-tree target-commit failure can therefore leave an earlier
  payload replacement visible beside the prior inventory; that failed run is
  not a successful publication and must be rerun; and
- the normal staged-publish and cross-volume limitations documented by the
  [HTML output contract](https://github.com/drawmeanelephant/boris/blob/afterparty/docs/contracts/html-output.md) continue to apply. No stronger
  universal filesystem atomicity claim is made here.

The inventory is visible with `status: "committed"` only after the surrounding
target commit succeeds. A failed pre-commit collection or write removes only
the current stage and leaves the previous target untouched.

## Projection boundary

This inventory says which Boris-owned payload bytes were committed and who
produced them. It does not establish semantic correctness, link integrity,
accessibility, schema conformance, deployment correctness, prose quality, or
universal reproducibility. Those are independent checks and claims governed by
the [publication model contract](publication-model.html) and each projection's
own contract.
