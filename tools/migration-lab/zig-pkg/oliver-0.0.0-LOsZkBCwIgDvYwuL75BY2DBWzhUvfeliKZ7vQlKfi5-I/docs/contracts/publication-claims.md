# Publication claims evidence (schema v1)

**Status:** normative target-local claims-and-limitations evidence contract

Each successful HTML target publication may emit one deterministic report at:

```text
{target}/_boris/proof/claims.json
```

The report is a bounded mechanical derivation over the committed artifact
inventory and publication checks evidence for one committed target. It is not
a proof-pack envelope, a human certification, a deployment result, an
accessibility result, a quality score, or a reproducibility certificate. It
can only ever say what the checks observed; see
[`publication-checks.md`](publication-checks.html) for the authority of those
observations.

## Authority and transaction boundary

`_boris/proof/artifacts.json` and `_boris/proof/checks.json` are the exclusive
inputs. The claims engine never re-reads payloads, never re-runs checks, and
never re-derives evidence. It binds both inputs by exact bytes:

```text
artifact_inventory  : path  = _boris/proof/artifacts.json
                      bytes = exact inventory byte count
                      sha256 = lowercase SHA-256 of the exact inventory bytes
                      format = boris-publication-artifacts
                      schema_version = 1
                      target = inventory target identity
                      artifact_count = inventory record count

publication_checks  : path  = _boris/proof/checks.json
                      bytes = exact checks byte count
                      sha256 = lowercase SHA-256 of the exact checks bytes
                      format = boris-publication-checks
                      schema_version = 1
                      target = checks target identity
                      check_count = check execution count
                      finding_count = root finding count
```

The HTML publication transaction is ordered as follows:

```text
stage payloads
→ stage artifacts.json
→ commit payload files
→ commit artifacts.json last
→ run publication checks against the committed target
→ atomically replace checks.json
→ derive claims strictly from committed artifacts.json and checks.json bytes
→ atomically replace claims.json
```

`claims.json` is not staged with payloads and is not included in
`artifacts.json`. A claim derivation failure after the checks commit does not
roll back the target or the checks report; it returns exit code `3` and
explicitly reports that the publication committed but its claims evidence was
not refreshed. Atomic report-write failure preserves the previous report, and
any failure before the atomic replace leaves the prior `claims.json` untouched.

Every claims derivation validates the checks report strictly before writing:
the checks format and schema version must match the checks contract exactly,
the checks target must equal the inventory target, the checks-embedded
artifact digest must equal the exact current inventory bytes, the check set
must be the fixed three in canonical order, and finding offsets and totals
must be coherent. A stale or malformed checks report prevents a new claims
report; it is reported as the explicit failure above, never written through.

## Fixed report shape

The root object has exactly these keys, in this order:

```text
format
schema_version
target
artifact_inventory
publication_checks
claims
limitations
```

The machine-readable schema is
[`schemas/publication-claims-1.schema.json`](https://github.com/drawmeanelephant/oliver/blob/main/docs/contracts/schemas/publication-claims-1.schema.json).
The report format is `boris-publication-claims`, with schema version `1`.

`claims` contains exactly three derivations, in this order, each bound to the
check of the same array position:

1. `committed-artifacts-match-inventory` ← `artifact-integrity`
2. `rendered-html-passed-declared-audit` ← `rendered-html`
3. `rendered-search-matches-selected-html` ← `rendered-search`

Each claim has exactly:

```text
id
statement
status
evidence
scope
limitation_ids
```

`status` is one of `verified`, `failed`, or `not-verified`, derived
mechanically from the bound check:

```text
check status      claim status    reason
passed            verified        (absent)
failed            failed          check-failed
incomplete        not-verified    check-incomplete
not-applicable    not-verified    check-not-applicable
```

`evidence` is the mechanical binding: the bound `check_id`, the check
`status` and `coverage`, the check `counts`, the check subject and supporting
scope digests, the SHA-256 of the exact `checks.json` bytes that the report
was derived from, and the derivation `reason` above when the claim is not
`verified`. `scope` repeats the check's subject/supporting status and kind
selectors. `limitation_ids` lists every limitation that applies to the claim.

`limitations` contains exactly six fixed rows, in this order:

1. `target-local-only` — claims describe one selected local HTML target after
   its commit and say nothing about any other target or environment.
2. `no-deployment-verification` — no deployment was performed or verified.
3. `no-accessibility-verification` — no accessibility audit was performed.
4. `no-prose-quality-verification` — no prose, writing, or documentation
   quality judgment was made.
5. `no-universal-reproducibility-claim` — deterministic bytes on one recorded
   environment are not universal reproducibility.
6. `omitted-projections-not-certified` — an omitted or unselected projection
   remains explicitly unverified (applies only to the rendered-search claim).

Each limitation row has exactly:

```text
id
statement
applies_to_claims
source
```

`source` cites the normative prose the limitation is anchored to. Claim
`limitation_ids` and limitation `applies_to_claims` always agree: the first
five limitations apply to every claim; the sixth applies only to
`rendered-search-matches-selected-html`.

The fixed three claims do not include a deployment-location claim. When a
normalized hosted location is configured, `EPUBLICATIONLOCATION` is a
pre-commit publication gate: a mismatch prevents target replacement and no
claims report is derived for that failed output. A successful claims report
therefore still does not certify deployment, post-deploy HTTP behavior, or
location-free IR/RAG/Context artifacts; those artifacts currently carry no
applicable public URL field.

## Determinism and limits

For identical inventory, checks, and payload bytes, two runs produce
byte-identical `claims.json`. The emitter uses fixed root/nested key order,
fixed claim and limitation order, canonical registry order, lowercase SHA-256,
UTF-8 JSON, and LF line endings. It emits no timestamp, duration, absolute
path, CWD, staging path, worker count, host, environment, username, PID, Git
revision, or filesystem traversal order.

The engine retains only canonical inventory metadata, the checks report
vocabulary, and the report under construction; payloads are never retained.

The report establishes only what the three named checks observed within the
declared target-local scope, with the six listed limitations attached. It does
not establish deployment behavior, accessibility, prose quality, universal
reproducibility, or correctness of an omitted projection.
