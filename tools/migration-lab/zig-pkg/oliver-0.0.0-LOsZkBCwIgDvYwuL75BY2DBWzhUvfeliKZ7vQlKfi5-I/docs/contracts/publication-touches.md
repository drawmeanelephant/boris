# Publication Touch Atlas (schema v1)

**Status:** implemented first slice

The Touch Atlas is a target-local evidence index for the first
publication-evidence chain. It answers structural questions by connecting
records that already exist in the artifact inventory, publication checks, and
publication claims reports:

- which inventory artifacts belong to a target;
- which artifacts are subjects or supporting inputs of each check;
- which findings belong to each check;
- which check supports each claim; and
- which limitations constrain each claim.

It does not create a new observation, check, claim, or limitation. The first
implemented slice derives `touches.json` exclusively from the exact committed
bytes of the three evidence reports; the non-claims listed at the end of this
document remain out of scope.

## Artifact and exclusive inputs

The target-local artifact is:

```text
{target}/_boris/proof/touches.json
```

Its fixed identity is:

```text
format: boris-publication-touches
schema_version: 1
```

The only inputs are the exact bytes of these three committed evidence reports:

```text
_boris/proof/artifacts.json
_boris/proof/checks.json
_boris/proof/claims.json
```

The Touch Atlas must not read or crawl pages, payloads, sources, deployment
resources, caches, or the output filesystem tree. It must not trace compiler
phases, runtime calls, individual transformations, or source provenance. Those
relationships are not present in the v1 evidence reports and must not be
fabricated.

## Root shape and input bindings

The root object has exactly these keys, in this order:

```text
format
schema_version
target
inputs
nodes
edges
```

`inputs` is an object with exactly these keys, in this order:

```text
artifacts
checks
claims
```

Each input binding copies the report identity and includes the exact byte
binding fields below. The digest is lowercase SHA-256 of the exact committed
report bytes, not of parsed or reserialized JSON.

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
  }
}
```

The counts are mechanically derived from the parsed input reports and then
validated against the embedded bindings:

```text
artifact_count   = artifacts.json artifacts array length
check_count      = checks.json checks array length
finding_count    = checks.json findings array length
claim_count      = claims.json claims array length
limitation_count = claims.json limitations array length
```

They do not replace validation of the actual arrays and bindings.

## Nodes

Every node is a closed object with exactly these keys, in this order:

```text
kind
id
metadata
```

`metadata` is also closed. The node `kind` identifies the Touch Atlas node
vocabulary; metadata fields are copied references to authoritative evidence,
not newly observed facts.

The v1 node kinds are exactly:

```text
target
artifact
check
finding
claim
limitation
```

Stable IDs and minimum metadata are:

| Node kind | Stable ID | Metadata, in order |
|---|---|---|
| `target` | `target` | `target` |
| `artifact` | `artifact:<artifact path>` | `inventory_index`, `path`, `kind`, `status`, `required` |
| `check` | `check:<check id>` | `check_index`, `check_id`, `status`, `coverage` |
| `finding` | `finding:<owning check id>:<zero-based ordinal within that check>` | `finding_index`, `check_id`, `check_finding_index`, `code`, `severity`, `subject` |
| `claim` | `claim:<claim id>` | `claim_index`, `claim_id`, `status` |
| `limitation` | `limitation:<limitation id>` | `limitation_index`, `limitation_id`, `source` |

The `subject` value is copied as the closed checks-contract object with
`kind`, `id`, and `target`; its `target` may be `null` when the source finding
uses a null target. Artifact paths and all copied path values remain
target-relative, slash-separated paths.

Nodes have one canonical order:

1. one `target` node;
2. artifacts in canonical artifact-inventory order, including records whose
   status is not `committed`;
3. checks in the fixed publication-check order;
4. findings in root finding order;
5. claims in the fixed publication-claim order; and
6. limitations in the fixed publication-limitation order.

The fixed v1 registries are the three checks and claims from the existing
contracts and the six limitations from `publication-claims.md`. Runtime
validation must reject missing, extra, reordered, or duplicated registry
members even where an individual object matches the JSON Schema.

## Edges

Every edge is a closed object with exactly these keys, in this order:

```text
kind
from
to
```

The v1 edge kinds are exactly:

```text
target-owns-artifact
artifact-subject-of-check
artifact-supports-check
check-reported-finding
check-supports-claim
claim-limited-by
```

Edge direction and derivation are:

| Edge | Direction | Derivation |
|---|---|---|
| `target-owns-artifact` | `target` → `artifact` | One edge for every inventory record, including non-committed records. |
| `artifact-subject-of-check` | `artifact` → `check` | The artifact matches the check's declared subject selectors. |
| `artifact-supports-check` | `artifact` → `check` | The artifact matches the check's declared supporting selectors. |
| `check-reported-finding` | `check` → `finding` | The finding lies in the check's validated contiguous `finding_offset`/`counts.findings` range. |
| `check-supports-claim` | `check` → `claim` | The claim's exact `evidence.check_id` binding resolves to the check; this is an evidence binding, not a statement that the check passed. |
| `claim-limited-by` | `claim` → `limitation` | The claim's ordered `limitation_ids` resolve to the limitation nodes. |

Artifact selector matching uses the publication-check contract's semantics:

- when both selector arrays are empty, the selected set is empty;
- otherwise, an empty individual dimension is a wildcard for that dimension;
- matching retains canonical inventory order.

Subject edges use `scope.subject_statuses` and `scope.subject_kinds`.
Supporting edges use `scope.supporting_statuses` and
`scope.supporting_kinds`. The scope SHA-256 values are evidence digests, not
additional selectors.

Edges are compared by this tuple, in order:

1. edge kind order;
2. source evidence index; then
3. destination evidence index.

For `target-owns-artifact`, the source is the single target node and the
destination uses artifact inventory order. For artifact-to-check edges, the
source evidence index is the artifact inventory index and the destination
evidence index is the fixed check index. For `check-reported-finding`, the
source is the fixed check index and the destination is the root finding order.
For `check-supports-claim`, the source is the fixed check index and the
destination is the fixed claim index. For `claim-limited-by`, claim order is
first and each claim's ordered limitation list is second; limitations are not
sorted by a separate global scan.

Runtime validation must reject duplicate `(kind, from, to)` tuples and every
dangling node reference. V1 deliberately does not create a
`finding`-to-`artifact` edge merely because a diagnostic subject resembles an
artifact path; exact finding-subject lineage is a separate design problem.

## Cross-report validation

Before a Touch Atlas is valid, a future implementation must fail closed unless
all of the following hold:

- every input format and schema version matches the v1 constants;
- all three report targets match the requested target and the root target;
- `checks.json` binds the exact current `artifacts.json` bytes;
- `claims.json` binds the exact current `artifacts.json` and `checks.json`
  bytes;
- derived `artifact_count` must agree with
  `checks.artifact_inventory.artifact_count` and
  `claims.artifact_inventory.artifact_count`;
- derived `check_count` and `finding_count` must agree with
  `claims.publication_checks.check_count` and
  `claims.publication_checks.finding_count`;
- the fixed check, claim, and limitation registries are valid and in
  canonical order;
- finding offsets and totals are coherent and cover the root findings without
  overlap or omission;
- every claim-to-check binding resolves;
- every limitation reference resolves in both directions between claim rows
  and limitation rows;
- every generated edge resolves to an existing node;
- node identities are unique; and
- edge tuples are unique.

The implementation must validate derived counts and copied metadata against
their source reports, including inventory indices, check/finding indices,
statuses, coverage, codes, claim statuses, and limitation sources. It must
preserve any prior
`touches.json` when validation or writing fails.

## Future publication transaction

The future publication order is:

```text
commit payloads
→ commit artifacts.json
→ commit checks.json
→ commit claims.json
→ derive touches from those exact committed evidence bytes
→ atomically replace touches.json
```

`touches.json` is downstream evidence:

- it is not staged with payloads;
- it is not included in `artifacts.json`;
- it does not alter `checks.json` or `claims.json`;
- its failure does not roll back payloads or earlier evidence;
- a failure returns exit code `3` and preserves any prior Touch Atlas; and
- the committed-target diagnostic is emitted even under `--quiet`.

These are reserved implementation semantics. This PR does not emit the
artifact, add a compiler command, or change the current publication
transaction.

## Determinism and limits

For identical committed input bytes, the implementation must produce
byte-identical output and require:

- exact-byte input bindings;
- one canonical node order and edge order;
- lowercase SHA-256;
- UTF-8 JSON and LF line endings;
- no timestamps or durations;
- no absolute paths or CWD;
- no host, PID, username, Git revision, or environment values;
- no filesystem traversal order;
- no payload rereads;
- no source-provenance claim;
- no deployment claim; and
- no transformation-runtime trace claim.

The Touch Atlas establishes only relationships already declared by the three
input reports. It does not upgrade a failed, incomplete, or not-applicable
check into a pass, and it does not turn a claim into universal verification.

## Schema boundary and runtime boundary

[`schemas/publication-touches-1.schema.json`](https://github.com/drawmeanelephant/oliver/blob/main/docs/contracts/schemas/publication-touches-1.schema.json)
enforces the structural boundary: exact root keys and constants, closed input
bindings, closed node and edge object shapes, the six node kinds, the six edge
kinds, required metadata, digest syntax, stable ID patterns, and permitted
edge directions.

JSON Schema does not prove cross-report facts. Runtime validation remains
responsible for exact input-byte digests, target equality, report-specific
binding equality, fixed registry order, canonical node and edge order, node
cardinality, identity collisions, selector-derived edge membership, finding
offset ranges, claim/limitation bidirectional agreement, duplicate edges, and
all node references. Atomic replacement, prior-report preservation, exit code
`3`, and quiet diagnostic capture are also runtime behavior rather than schema
claims.

## Implementation status

The first slice ships:

1. `src/publication_touches.zig` — strict streaming parsers for the three
   reports, cross-report validation, canonical node/edge derivation, and
   deterministic serialization, plus schema/runtime parity tests.
2. `src/compile.zig` integration — derives the atlas only from the exact
   committed evidence bytes after claims replacement, with no payload rereads.
3. `src/main.zig` exit mapping — preserves the existing committed-target
   diagnostic and maps Touch Atlas failure to exit `3`, including `--quiet`.
4. Artifact-inventory reserved-path guards — reserves and rejects
   `_boris/proof/touches.json` without inventorying it.
5. Fixture tests — cover clean, failed/incomplete, not-applicable search,
   stale bindings, selector wildcards, duplicate identities, dangling edges,
   byte determinism across sequential and concurrent runs, and reserved-path
   collision guards.
6. Build steps — focused `test-publication-touches` and
   `test-publication-touches-fixture` targets wired into the root test suite,
   without changing the product build architecture.
7. Quiet diagnostic capture — the committed-target diagnostic is retained
   under `--quiet` and is captured by an injectable writer seam.

## Non-claims (explicitly out of scope)

This slice makes no claim about, and does not attempt:

- source-to-artifact provenance (no source files are read);
- runtime transformation traces (no compiler phase or call tracing);
- a deployment graph (no deployment resources are read or verified);
- accessibility or prose-quality inference;
- proof-pack presentation or packaging; and
- repair actions (the atlas never rewrites a payload, report, or claim).

The status is **implemented first slice**: the normative runtime requirements
above are enforced by `zig build test-publication-touches` and the fixture
suite, and the atlas never rereads payloads or source bytes.
