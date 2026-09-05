# Publication Proof Pack examples

**Status:** implemented and shipped — Boris emits `_boris/proof/proof-pack.json`
and `_boris/proof/index.html` on every build.

These files are hand-checkable examples for the
[`publication-proof-pack.md`](../../contracts/publication-proof-pack.md)
schema and its static HTML rendering. They are illustrative evidence
snapshots, not compiler output.

Each JSON example is a complete `proof-pack.json` model. Each HTML example is
a static rendering derived exclusively from the corresponding model. The
`touches` input binding in each example is the exact SHA-256 of the matching
[Touch Atlas example](../publication-touches/examples/), so the examples are
cross-checkable: the Proof Pack's `artifacts`, `checks`, and `claims`
bindings agree with the bindings the Touch Atlas example itself embeds.

## Examples

| Example | Presentation | Artifacts | Checks | Findings | Claims | Limitations | Nodes | Edges |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| [`clean.json`](examples/clean.json) | `verified` | 2 | 3 | 0 | 3 | 6 | 15 | 28 |
| [`attention-required.json`](examples/attention-required.json) | `attention-required` | 5 | 3 | 3 | 3 | 6 | 21 | 40 |
| [`search-not-applicable.json`](examples/search-not-applicable.json) | `attention-required` | 2 | 3 | 0 | 3 | 6 | 15 | 27 |

The HTML examples are derived from the JSON models of the same row:

| HTML | Model | Banner |
|---|---|---|
| [`index-clean.html`](examples/index-clean.html) | `clean.json` | `verified` |
| [`index-attention-required.html`](examples/index-attention-required.html) | `attention-required.json` | `attention-required` |

## Expected counts

Supporting edges follow the shipped selector semantics: every committed
artifact supports `rendered-html`, and committed `html-page` records support
`rendered-search`.

### `clean.json` — all checks passed, all claims verified

- **Artifact rows (2):** `index.html` (html-page, committed, required) and
  `_boris/search/search-index.json` (rendered-search, committed, required).
  Both carry `bytes` and `sha256`.
- **Check rows (3):** `artifact-integrity`, `rendered-html`,
  `rendered-search` — each `passed` / `complete` / eligible / ran, with
  counts `eligible 2,1,1` and `checked 2,1,1` and `findings 0,0,0`.
- **Finding rows (0):** empty.
- **Claim rows (3):** all `verified`; `evidence_check_id` matches the bound
  check; `limitation_ids` are the five common limitations, with
  `omitted-projections-not-certified` added to the rendered-search claim.
- **Limitation rows (6):** all six fixed limitations, with `source` anchors
  copied from the claims contract. Limitations are visible even though all
  claims are verified — the clean case is the proof.
- **Relationship bindings:** 15 nodes (1 target + 2 artifacts + 3 checks +
  3 claims + 6 limitations); 28 edges = 2 owns + 4 subject + 3 supports +
  0 findings + 3 claims + 16 limits. Every edge tuple exists in the matching
  Touch Atlas example.
- **Summary totals:** artifacts `total 2`; checks `total 3, passed 3`;
  findings `total 0`; claims `total 3, verified 3`;
  `limitation_count 6`; `relationship_node_count 15`;
  `relationship_edge_count 28`.
- **Overall presentation status:** `verified`.

### `attention-required.json` — failed checks with visible findings and limitations

- **Artifact rows (5):** `index.html`, `broken.html` (both html-page,
  committed), `_boris/search/search-index.json` (rendered-search,
  committed), `assets/site.css` (theme-asset, committed), and
  `assets/legacy.css` (theme-asset, **omitted-by-plan**, not required).
  The non-committed `legacy.css` record omits `bytes` and `sha256` rather
  than inventing zero values.
- **Check rows (3):** each `failed` / `complete` / eligible / ran, with
  findings `1,1,1` and `finding_ids` covering the root finding range.
- **Finding rows (3):** `ARTIFACT_DIGEST_MISMATCH` (error,
  `broken.html`), `HTML_FRAGMENT_MISSING` (error, `index.html`), and
  `SEARCH_CONTENT_MISMATCH` (error, search index). Subjects are copied
  verbatim; no finding-to-artifact edge is inferred.
- **Claim rows (3):** all `failed`; statements copied exactly from claims
  evidence; `limitation_ids` unchanged.
- **Limitation rows (6):** identical to the clean example.
- **Relationship bindings:** 21 nodes (1 + 5 + 3 + 3 + 3 + 6); 40 edges =
  5 owns + 7 subject + 6 supports + 3 findings + 3 claims + 16 limits.
  `legacy.css` receives a `target-owns-artifact` edge but no
  artifact-to-check edge.
- **Summary totals:** artifacts `total 5, committed 4, omitted-by-plan 1`;
  checks `failed 3`; findings `total 3, error 3`; claims `failed 3`;
  `limitation_count 6`; `relationship_node_count 21`;
  `relationship_edge_count 40`.
- **Overall presentation status:** `attention-required`.

### `search-not-applicable.json` — rendered search not applicable

- **Artifact rows (2):** `index.html` (html-page, committed) and
  `assets/site.css` (theme-asset, committed).
- **Check rows (3):** `artifact-integrity` and `rendered-html` `passed` /
  `complete`; `rendered-search` is `not-applicable` / `not-applicable`,
  `eligible: false`, `ran: false`, with zero counts and no finding ids. It
  keeps its supporting page edge (`index.html` → rendered-search) exactly as
  the Touch Atlas declares it.
- **Finding rows (0):** empty.
- **Claim rows (3):** first two `verified`; the rendered-search claim is
  `not-verified` because its bound check is `not-applicable`. The claim is
  not upgraded by the Proof Pack.
- **Limitation rows (6):** unchanged, including
  `omitted-projections-not-certified` for the search claim.
- **Relationship bindings:** 15 nodes; 27 edges = 2 owns + 3 subject +
  3 supports + 0 findings + 3 claims + 16 limits.
- **Summary totals:** artifacts `total 2`; checks `passed 2,
  not-applicable 1`; findings `total 0`; claims `verified 2,
  not-verified 1`; `limitation_count 6`; `relationship_node_count 15`;
  `relationship_edge_count 27`.
- **Overall presentation status:** `attention-required` — a not-verified
  claim is enough to leave `verified`, even though every applicable check
  passed.

## Validation

Validate the three JSON examples against
[`publication-proof-pack-1.schema.json`](../../contracts/schemas/publication-proof-pack-1.schema.json)
with a Draft 2020-12 JSON Schema validator (for example Ajv with
`--spec=draft2020`). Schema validation covers object shape, constants,
closed enums, digest syntax, stable node IDs, fixed registry counts, and the
overall-status vocabulary. It does not prove exact report bytes, target
equality, Touch Atlas binding agreement, canonical ordering, derived counts,
selector-derived edge membership, finding offsets, the mechanical
overall-status derivation, or summary totals; the shipped runtime derives
those, and its golden and parity tests pin them.

Check the two HTML examples with the repository-compatible
[`check-parity.py`](check-parity.py) script (Python standard library only,
no new runtime dependency):

```bash
python3 docs/audits/publication-proof-pack/check-parity.py
```

The script is the HTML-to-JSON parity check. For each paired model and page it
compares at least: target, format, schema version, overall presentation
status, embedded model digest, summary totals, artifact
paths/statuses/bytes/digests (including non-committed records), check
status/coverage/counts, finding IDs/codes/severities/subjects, claim
IDs/statements/statuses, limitation IDs/statements/sources, relationship node
IDs, and relationship edge tuples. It also rejects any rendered relationship
group heading the model does not declare, so a page cannot invent a group. A
tag-balance or anchor check alone is insufficient; the script exits 0 only
when every displayed fact matches the model. The embedded
`proof-pack-sha256` meta value in each page is checked against the exact
SHA-256 of the paired JSON bytes.

Separately, the same stdlib parser proves structural tag balance, resolved
`#` anchors, UTF-8, and the absence of `<script>` and remote
`src`/`href`/`@import`. This is a structural and resource check, not an HTML5
conformance validation: it does not assert HTML5-conformant markup beyond
well-formedness. (The repo's system `tidy` is an HTML4 parser that does not
recognize HTML5 elements, so it is not a suitable HTML5 validator here.) The
HTML must remain fully static, no-JavaScript, anchor-navigable, printable,
and free of remote resources.
