# Publication Proof Pack (schema v1)

**Status:** implemented and shipped (first slice)

The Proof Pack is the presentation and packaging layer over Boris's committed
publication evidence. The Touch Atlas connects the evidence; the Proof Pack
makes that evidence understandable and portable without creating new
verification.

Boris emits the deterministic pair `_boris/proof/proof-pack.json` and
`_boris/proof/index.html` as the final presentation layer after the Touch
Atlas commits. The runtime requirements below are enforced by compiler and
fixture tests; see the implementation map at the end of this document.

## Purpose

The Proof Pack must let a human answer:

```text
What was published?
What was checked?
What passed, failed, remained incomplete, or was not applicable?
Which claims are supported?
Which limitations constrain those claims?
How do those facts connect?
What evidence files were used?
```

It is a presentation and packaging layer over committed evidence. It is a
deterministic two-file target-local pair: an authoritative JSON presentation
model and a static HTML rendering derived exclusively from that model.

### Non-claims

The Proof Pack must not:

- rerun checks;
- reread payloads;
- inspect deployment state;
- infer source provenance;
- claim accessibility;
- claim prose quality;
- claim universal reproducibility;
- repair anything; or
- upgrade evidence status.

The Proof Pack is downstream of the evidence chain. It copies, binds, and
presents; it never re-observes. A rendered page cannot make a failed or
incomplete check look successful, and a pretty summary is not a new
verification claim.

## Outputs

Define two target-local outputs:

```text
_boris/proof/proof-pack.json
_boris/proof/index.html
```

- `proof-pack.json` is the authoritative deterministic presentation model.
- `index.html` is a deterministic static rendering derived exclusively from
  that model.

Neither output belongs in `artifacts.json`, because both are downstream
evidence presentation owned by Boris. The reserved-path guard that rejects
`_boris/proof/touches.json` as a producer-owned inventory path must also
reject `_boris/proof/proof-pack.json` and `_boris/proof/index.html`.

## Exclusive inputs

The Proof Pack may read only the exact committed bytes of:

```text
_boris/proof/artifacts.json
_boris/proof/checks.json
_boris/proof/claims.json
_boris/proof/touches.json
```

It must bind each by:

```text
path
bytes
sha256
format
schema_version
target
```

The Touch Atlas binding must itself resolve to the same exact artifacts,
checks, and claims bytes: `touches.json` embeds its own `inputs` bindings, and
the Proof Pack must verify that those three bindings agree byte-for-byte with
the Proof Pack's own `artifacts`, `checks`, and `claims` bindings. The four
inputs are committed evidence reports; no payload, source, cache, deployment,
or target-tree traversal is allowed.

## `proof-pack.json` root

Define this exact root order:

```text
format
schema_version
target
inputs
summary
artifacts
checks
findings
claims
limitations
relationships
presentation
```

Identity:

```text
format: boris-publication-proof-pack
schema_version: 1
```

The root object has exactly these keys. Canonical member ordering is assigned
to the runtime serializer, exact-byte golden tests, and HTML/JSON parity
tests; the schema enforces the exact key set and structural vocabulary, not
object property order (JSON Schema Draft 2020-12 does not enforce member
order). The machine-readable schema is
[`schemas/publication-proof-pack-1.schema.json`](https://github.com/drawmeanelephant/oliver/blob/main/docs/contracts/schemas/publication-proof-pack-1.schema.json).

## Input bindings

`inputs` is an object with exactly these keys, in this order:

```text
artifacts
checks
claims
touches
```

Each binding copies the report identity and includes the exact byte binding
fields. The digest is lowercase SHA-256 of the exact committed report bytes,
not of parsed or reserialized JSON.

```json
{
  "artifacts": {
    "path": "_boris/proof/artifacts.json",
    "bytes": 0,
    "sha256": "lowercase-64-hex-digest",
    "format": "boris-publication-artifacts",
    "schema_version": 1,
    "target": "public",
    "artifact_count": 0
  },
  "checks": {
    "path": "_boris/proof/checks.json",
    "bytes": 0,
    "sha256": "lowercase-64-hex-digest",
    "format": "boris-publication-checks",
    "schema_version": 1,
    "target": "public",
    "check_count": 3,
    "finding_count": 0
  },
  "claims": {
    "path": "_boris/proof/claims.json",
    "bytes": 0,
    "sha256": "lowercase-64-hex-digest",
    "format": "boris-publication-claims",
    "schema_version": 1,
    "target": "public",
    "claim_count": 3,
    "limitation_count": 6
  },
  "touches": {
    "path": "_boris/proof/touches.json",
    "bytes": 0,
    "sha256": "lowercase-64-hex-digest",
    "format": "boris-publication-touches",
    "schema_version": 1,
    "target": "public",
    "node_count": 0,
    "edge_count": 0
  }
}
```

Counts are mechanically derived from the parsed input reports and validated
against the embedded bindings:

```text
artifact_count   = artifacts.json artifacts array length
check_count      = checks.json checks array length
finding_count    = checks.json findings array length
claim_count      = claims.json claims array length
limitation_count = claims.json limitations array length
node_count       = touches.json nodes array length
edge_count       = touches.json edges array length
```

They do not replace validation of the actual arrays and bindings.

## Summary

The summary must be entirely mechanical. Every number is derived by counting
the presentation rows or by an ordered status comparison — never by a new
observation.

Include:

```text
artifact totals by status and kind
check totals by status and coverage
finding totals by severity
claim totals by status
limitation count
relationship node count
relationship edge count
overall presentation status
```

### Overall presentation status

The overall presentation status is **not** a new verification claim. It is a
closed mechanical vocabulary:

```text
verified
attention-required
incomplete
not-applicable
```

It is derived by this exact ordered rule set, using only the check and claim
statuses copied from the committed evidence:

1. If every check status is `not-applicable`, the status is `not-applicable`.
2. Otherwise, if any check status is `incomplete`, the status is
   `incomplete`.
3. Otherwise, if any check status is `failed`, or any claim status is
   `failed`, or any claim status is `not-verified`, the status is
   `attention-required`.
4. Otherwise, the status is `verified` (every check is `passed` and every
   claim is `verified`).

A single failed or incomplete check, or a single failed or not-verified
claim, is sufficient to leave `verified`. The derivation never upgrades a
claim or check, and it never invents a pass. The same derivation is used for
both the JSON `summary` and the HTML banner; a mismatch between the two is an
implementation defect.

Under the fixed v1 check registry, the `not-applicable` overall status is
unreachable in practice: `artifact-integrity` and `rendered-html` are always
applicable for a valid inventory, so "every check not-applicable" cannot
occur. The term remains part of the closed vocabulary for future registries
and degenerate inventories, and rule 1 keeps the derivation total. A
`not-applicable` check that produces a `not-verified` claim therefore
resolves to `attention-required`, never to `not-applicable`.

Avoid words such as:

```text
healthy
excellent
safe
correct
production-ready
```

unless they are part of an explicitly quoted upstream claim.

## Artifact presentation rows

For every artifact inventory record, include:

```text
inventory_index
path
kind
status
required
bytes
sha256
related_check_ids
related_claim_ids
```

For non-committed records, omit unavailable committed-byte properties exactly
as required by the artifact contract rather than inventing zero values:
`bytes` and `sha256` are present only for `status: committed` records and are
omitted for `omitted-by-plan` and `not-applicable` records.

Relationships must come from `touches.json`, not be independently recomputed
from selectors:

- `related_check_ids` lists the check IDs of every check the artifact is a
  subject of or a supporting input for, via `artifact-subject-of-check` and
  `artifact-supports-check` edges.
- `related_claim_ids` lists the claim IDs supported by those checks via
  `check-supports-claim` edges, restricted to the checks related to this
  artifact.

Rows keep canonical artifact-inventory order, including non-committed
records.

## Check presentation rows

For each fixed check:

```text
check_index
check_id
status
coverage
eligible
ran
counts
finding_ids
subject_artifact_ids
supporting_artifact_ids
supported_claim_ids
```

- `counts` copies the check's `counts` object (`eligible`, `checked`,
  `findings`).
- `finding_ids` lists the finding node IDs in that check's contiguous
  `finding_offset`/`counts.findings` range, in root finding order.
- `subject_artifact_ids` and `supporting_artifact_ids` come from
  `artifact-subject-of-check` and `artifact-supports-check` edges.
- `supported_claim_ids` comes from `check-supports-claim` edges.

Do not summarize a failed or incomplete check as successful merely because
the Proof Pack rendered without error. Status and coverage are copied
verbatim; no rendering success may upgrade them.

## Finding presentation rows

The root `findings` array appears immediately after `checks`, before `claims`.
For each finding:

```text
finding_index
finding_id
check_id
code
severity
subject
```

`finding_id` is the Touch Atlas node ID (`finding:<check id>:<ordinal>`), and
`subject` is the closed subject object copied from the finding. Do not infer
a finding-to-artifact relationship from path resemblance; v1 deliberately
creates no finding-to-artifact edge.

The ordered array must correspond exactly to root finding order in
`checks.json`. The runtime must prove all of the following before the model
is valid:

- `findings.length` equals the `checks` input binding's `finding_count`;
- every check's `finding_ids` exactly selects its contiguous
  `finding_offset`/`counts.findings` range, with no overlap or omission
  across the root array;
- every finding row's node ID exists in the Touch Atlas `nodes`, and the
  owning check's `check-reported-finding` edge exists in the Touch Atlas
  `edges`; and
- no finding row is invented (from path resemblance or any other guess) and
  no committed finding is omitted.

The check rows and the root `findings` array must agree with each other and
with the checks evidence: root finding order is authoritative, and each
check's `finding_ids` is a range selector, not an independent list.

## Claim presentation rows

For each claim:

```text
claim_index
claim_id
statement
status
evidence_check_id
limitation_ids
```

The statement and status must be copied exactly from claims evidence. No
rendering, summary, or presentation decision may reword a statement or
upgrade a status.

## Limitation presentation rows

For each limitation:

```text
limitation_index
limitation_id
statement
source
applies_to_claim_ids
```

Limitations must remain visible even when all claims are verified. The clean
example proves this: all six limitations are rendered in the clean case. The
HTML must show limitations in the verified presentation, not only when
attention is required.

## Relationships

Do not copy the complete Touch Atlas graph blindly. Define a compact
presentation index that preserves exact node and edge IDs while grouping
relationships for convenient rendering.

`relationships` is an object with:

```text
node_ids
groups
```

- `node_ids` is the ordered list of every Touch Atlas node ID, in the Touch
  Atlas canonical node order.
- `groups` is an array of edge-kind groups, in the fixed v1 edge-kind order
  (`target-owns-artifact`, `artifact-subject-of-check`,
  `artifact-supports-check`, `check-reported-finding`,
  `check-supports-claim`, `claim-limited-by`). Each group has the edge kind
  and its edges as `{ "from": node-id, "to": node-id }` pairs.

Node IDs are the closed Touch Atlas stable-ID vocabulary: `target`,
`artifact:<artifact path>`, `check:<check id>`,
`finding:<owning check id>:<ordinal>`, `claim:<claim id>`, and
`limitation:<limitation id>`. The schema constrains every `node_ids` entry
and every edge `from`/`to` endpoint to those patterns; an arbitrary string
fails validation.

Every relationship must bind to an exact existing Touch Atlas edge — the same
`(kind, from, to)` tuple must appear in `touches.json`. No relationship may be
added because it seems intuitive. Groups may be empty, but every edge in
`touches.json` must appear in exactly one group, and no edge may be invented.

## HTML requirements

The `_boris/proof/index.html` must be:

- fully static;
- valid UTF-8;
- deterministic;
- usable without JavaScript;
- navigable by headings and anchors;
- printable;
- readable directly from disk;
- free of remote fonts, scripts, images, analytics, or stylesheets;
- styled with embedded bounded CSS;
- clear about failed, incomplete, not-applicable, and limited evidence; and
- honest when a section contains no applicable records.

Allow progressive enhancement only when the complete content remains available
without JavaScript. Do not create an interactive graph dependency in v1; the
relationship section is a compact readable index, not a canvas or JS graph.

The HTML is derived exclusively from `proof-pack.json`. It must render the
same summary banner, artifact/check/finding/claim/limitation rows, and
relationship groups; it must not add, remove, reword, or upgrade any fact.
It must also embed the lowercase SHA-256 of the exact `proof-pack.json`
bytes it represents (for example in a meta element or comment) so a reader
can detect a stale partner without needing the JSON open beside it.

## Transaction

Define the order:

```text
payloads
→ artifacts.json
→ checks.json
→ claims.json
→ touches.json
→ proof-pack.json
→ index.html
```

Required behavior:

- Proof Pack failure does not roll back earlier publication or evidence;
- failure returns exit 3;
- diagnostic states that publication and prior evidence committed but Proof
  Pack presentation was not refreshed;
- diagnostic appears under `--quiet`; and
- on a handled synchronous failure, the prior `proof-pack.json` and
  `index.html` pair is preserved (restored or never touched) when
  restoration succeeds; when restoration itself fails, the run makes no
  prior-pair-preservation claim (see the first-slice transaction below).

### First-slice generation transaction

Two files cannot be renamed by one filesystem primitive, so the first slice
must not claim that sequential renames give concurrent readers atomic pair
visibility. The implementable transaction is:

1. Build both outputs completely from the same in-memory model, so the pair
   is one logical generation before any disk write.
2. Write and verify both temporary files (`proof-pack.json.tmp` and
   `index.html.tmp`) in the same directory; fsync and byte-verify both.
3. Embed in `index.html` the lowercase SHA-256 of the exact
   `proof-pack.json` bytes it represents (for example in a meta element or
   comment), so a reader can detect a stale partner.
4. Move the current pair aside (rename `index.html` → `index.html.prev` and
   `proof-pack.json` → `proof-pack.json.prev`) so that restoration has a
   defined source.
5. Rename the new `index.html` into place first.
6. Rename the new authoritative `proof-pack.json` last, as the logical
   commit point.
7. On success, delete the `.prev` files.
8. On a synchronous failure at any step, restore the prior pair by renaming
   the `.prev` files back over any partial new files. Restoration can
   itself fail; define that case explicitly:
   - if restoration succeeds, the prior pair remains, the run returns exit
     3, and the diagnostic (visible under `--quiet`) states that
     publication and prior evidence committed but Proof Pack presentation
     was not refreshed;
   - if restoration fails, the run still returns exit 3 and the diagnostic
     (visible under `--quiet`) states that presentation recovery failed and
     the current pair may be split or absent. Preserve the `.prev` files
     wherever possible; the next generation performs recovery or replaces
     both files. Do not claim prior-pair preservation when restoration
     failed.
9. A successful return guarantees that both current files match: the
   committed `proof-pack.json` bytes are exactly the bytes the committed
   `index.html` was derived from.
10. A reader that observes a mismatch between the HTML's embedded model
    digest and the on-disk `proof-pack.json` digest can detect a split pair
    and must not treat it as a committed generation.
11. A crash or a concurrent reader may observe an intermediate state between
    the two renames. The first slice makes no multi-file atomic-visibility
    claim; genuinely atomic pair visibility would require future single-entry
    indirection (for example a generation directory or a commit marker that
    readers consult before reading either file), which is out of scope for
    v1.

The embedded model digest is the first-slice mechanism that avoids a
committed split-generation pair: it is deterministic, cheap to verify, and
requires no multi-file atomic primitive. This transaction does not claim
whole-tree atomicity beyond the two files.

## Determinism

Require:

- exact input-byte bindings;
- canonical ordering inherited from upstream evidence (inventory order, fixed
  check order, root finding order, fixed claim order, fixed limitation order,
  Touch Atlas node/edge order);
- stable anchors derived from stable IDs (HTML fragment ids derived from node
  IDs and row indices);
- lowercase SHA-256;
- UTF-8 and LF;
- no timestamps;
- no durations;
- no absolute paths;
- no CWD;
- no host, PID, username, Git state, or environment;
- no filesystem traversal;
- no payload rereads;
- no random IDs;
- no locale-dependent sorting; and
- no external assets.

## Schema boundary and runtime boundary

[`schemas/publication-proof-pack-1.schema.json`](https://github.com/drawmeanelephant/oliver/blob/main/docs/contracts/schemas/publication-proof-pack-1.schema.json)
enforces the exact key set and structural vocabulary: required root keys,
constants, closed input bindings, closed row shapes, enum vocabularies,
digest syntax, stable node ID patterns, fixed registry counts, and the
overall-status vocabulary. JSON Schema Draft 2020-12 does not enforce object
property order, so the schema constrains key membership and array positions
where `prefixItems` applies, never member ordering. Canonical member ordering
is assigned to the runtime serializer, exact-byte golden tests, and HTML/JSON
parity tests.

JSON Schema does not prove cross-report facts. Runtime validation remains
responsible for exact input-byte digests, target equality, the Touch Atlas
three-binding agreement, canonical member ordering, derived counts,
selector-derived edge membership, finding offset ranges and contiguity, the
mechanical overall-status derivation, summary totals, HTML/JSON parity, the
first-slice generation transaction (including the embedded model digest and
split-pair detection), exit code `3`, quiet diagnostic capture, and
reserved-path guards. Atomic replacement and prior-pair preservation are
runtime behavior, not schema claims.

## Implementation map

The shipped first slice covers:

```text
src/publication_proof_pack.zig
strict four-report parsing and binding
Touch Atlas edge validation
finding-row derivation, contiguity, and Touch Atlas binding
summary derivation
deterministic JSON renderer
deterministic HTML renderer
first-slice generation transaction with embedded model digest
reserved-path collision guards
compile integration
exit mapping
quiet diagnostic capture
schema/runtime parity tests
fixture tests
HTML snapshot tests
HTML/JSON parity tests
failure injection
```

## Non-claims (explicitly out of scope)

This slice makes no claim about, and does not attempt:

- rerunning checks or re-reading payloads;
- deployment, accessibility, prose-quality, or reproducibility claims;
- source-to-artifact provenance inference;
- repair actions or evidence-status upgrades; and
- any multi-file atomic pair-visibility primitive (the first-slice
transaction makes no such claim; the embedded model digest is the
split-pair detection mechanism).

The presentation layer is implemented and shipped: Boris now emits
`_boris/proof/proof-pack.json` and `_boris/proof/index.html` after the
Touch Atlas commits, and the normative runtime requirements above are
enforced by the compiler, module, and fixture tests in this PR.
