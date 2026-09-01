# Publication checks evidence (schema v1)

**Status:** normative target-local publication evidence contract

Each successful HTML target publication may emit one deterministic report at:

```text
{target}/_boris/proof/checks.json
```

The report is a bounded mechanical result for one committed target. It is not
a proof-pack envelope, a claim engine, a limitations layer, a deployment
check, an accessibility result, a quality score, or a reproducibility
certificate.

## Authority and transaction boundary

`_boris/proof/artifacts.json` is the exclusive authority for Boris-owned
publication payloads. Checks do not crawl the target tree, infer ownership
from extensions or directories, or treat a deployment-owned extra file as a
Boris subject. The report records the exact inventory bytes it parsed:

```text
path       = _boris/proof/artifacts.json
bytes      = exact inventory byte count
sha256     = lowercase SHA-256 of the exact inventory bytes
format     = boris-publication-artifacts
schema_version = 1
target     = inventory target identity
artifact_count = inventory record count, including non-committed records
```

The HTML publication transaction is ordered as follows:

```text
stage payloads
→ stage artifacts.json
→ commit payload files
→ commit artifacts.json last
→ run publication checks against the committed target
→ atomically replace checks.json
```

`checks.json` is not staged with payloads and is not included in
`artifacts.json`. A failed or incomplete check still produces a valid report.
An inventory/parser/checker/write failure after the target commit does not
roll back the target; it returns exit code `3` and explicitly reports that the
publication committed but its evidence was not refreshed. Atomic report-write
failure preserves the previous report.

## Fixed report shape

The root object has exactly these keys, in this order:

```text
format
schema_version
target
artifact_inventory
checks
findings
```

The machine-readable schema is
[`schemas/publication-checks-1.schema.json`](https://github.com/drawmeanelephant/oliver/blob/main/docs/contracts/schemas/publication-checks-1.schema.json).
The report format is `boris-publication-checks`, with schema version `1`.

`checks` contains exactly three executions, in this order:

1. `artifact-integrity`
2. `rendered-html`
3. `rendered-search`

Each execution has exactly:

```text
id
eligible
ran
status
coverage
scope
counts
finding_offset
```

`status` is one of `passed`, `failed`, `incomplete`, or `not-applicable`.
`coverage` is one of `complete`, `incomplete`, or `not-applicable`.

`counts.eligible` is the number of declared subjects in the check’s selected
scope; `counts.checked` is the number of those subjects whose bytes were read
or whose selected check input was inspected; `counts.findings` is the number
of root findings owned by that check. `finding_offset` is the zero-based start
of that check’s contiguous range in the root `findings` array. Ranges appear
in check order and do not repeat a finding.

`scope` contains exactly:

```text
subject_statuses
subject_kinds
subject_sha256
supporting_statuses
supporting_kinds
supporting_sha256
```

When both selector arrays are empty, the selected scope is empty. Otherwise an
empty individual dimension is a wildcard for that dimension. Scope digests
select matching records from the canonical inventory order and hash
these exact bytes for each selected record:

```text
path NUL kind NUL bytes-decimal NUL sha256 LF
```

The selected records remain in inventory order. The SHA-256 of the empty byte
sequence is used for an empty selected set. Complete path lists are never
repeated inside check executions.

## Check eligibility and findings

### `artifact-integrity`

This check is selected whenever the inventory is valid, including a valid
zero-record inventory. Its subjects are every record with `status: committed`.
For every subject, the checker opens the target-relative path with no-follow
semantics, requires a regular file, compares the exact byte count, and
compares the exact lowercase SHA-256 digest. Every successfully read mismatch
is completely inspected and makes the check `failed`. A missing subject makes
coverage `incomplete` and makes the check `incomplete`. Symlink, non-regular,
unexpected access, or other system failure is a checker execution failure,
not a normal finding.

The three stable Doctor codes are:

```text
ARTIFACT_MISSING
ARTIFACT_SIZE_MISMATCH
ARTIFACT_DIGEST_MISMATCH
```

All three use `domain: artifact`, `severity: error`,
`confidence: certain`, `owner: publication`, and `fixability: regenerate`.
Every target file not named by the inventory is ignored.

### `rendered-html`

This check is selected for every valid inventory, including a zero-page HTML
target. Its subjects are committed records with `kind: html-page`. The exact
HTML bytes read by artifact integrity are passed directly to Doctor’s
incremental `TargetAnalysisBuilder` and released after each page. Doctor keeps
only canonical page state and derived search-document information; the checker
does not reread or re-render HTML. The intended route-membership set is every
committed inventory path.

It reuses these Doctor findings and ownership behavior:

```text
HTML_PAGE_MISSING
HTML_MALFORMED
HTML_URL_MALFORMED
HTML_LOCAL_ROUTE_MISSING
HTML_LOCAL_ROUTE_ESCAPE
HTML_FRAGMENT_MISSING
HTML_DUPLICATE_ID
```

When a hosted publication location is configured, the HTML producer also runs
the semantic publication-location gate before target commit. Its
`EPUBLICATIONLOCATION` diagnostic covers project-site base-path omissions and
Boris-owned canonical/public URLs with the wrong origin or path. This gate is
part of the HTML publication transaction, not a fourth `checks` execution and
not a new claims registry entry: a mismatch aborts target replacement, so no
committed target-local evidence can honestly describe that output as passed.
The three post-commit checks remain target-local and do not claim deployment or
post-deploy HTTP behavior.

A file outside the inventory cannot become a subject, create a stale finding,
or satisfy a Boris-owned route reference. A complete scope with error or
warning findings is `failed`; an incomplete scope is `incomplete` even when
other findings also exist. Informational findings alone do not fail a check.

### `rendered-search`

This check is eligible only when the committed inventory contains exactly one
`kind: rendered-search` record. With no such record it has:

```text
eligible: false
ran: false
status: not-applicable
coverage: not-applicable
```

Search selection is not inferred from filesystem existence or the publication
plan. Its supporting page set is every committed `html-page` record. The exact
selected search bytes are read during integrity inspection and passed to the
incremental Doctor analysis. It reuses:

```text
SEARCH_MISSING
SEARCH_MALFORMED
SEARCH_DOCUMENT_MISSING
SEARCH_DOCUMENT_STALE
SEARCH_CONTENT_MISMATCH
```

More than one committed `rendered-search` record is an ambiguous inventory
selection and prevents a new report; it is not treated as a normal finding.

## Status rules

`passed` requires complete inspection of the entire eligible declared scope
and no error or warning findings. `failed` means the entire eligible scope was
inspected and at least one error or warning finding was produced. `incomplete`
means any eligible subject could not be completely inspected; it outranks
`failed`. `not-applicable` means the check family was not selected by the
authoritative inventory. No findings never turns an incomplete inspection
into `passed`.

All root findings use the existing Doctor finding fields and meanings exactly:
`code`, `domain`, `severity`, `confidence`, `owner`, `subject`, source/output/
configuration locations, `evidence`, `remediation`, and `fixability`.

## Determinism and limits

For identical inventory and payload bytes, two runs produce byte-identical
`checks.json`. The emitter uses fixed root/nested key order, fixed check order,
canonical inventory order, existing Doctor finding order within each check,
sorted/deduplicated related evidence, lowercase SHA-256, UTF-8 JSON, and LF
line endings. It emits no timestamp, duration, absolute path, CWD, staging
path, worker count, host, environment, username, PID, Git revision, or
filesystem traversal order.

Artifact payloads are processed with a fixed-size read buffer, incremental
SHA-256, and a byte counter. At most the current HTML payload and the selected
rendered-search payload are transiently retained; non-HTML artifacts are never
retained as complete payloads. The inventory is parsed with a strict streaming
parser and only canonical inventory metadata is retained. This bounds working
memory by canonical inventory metadata, Doctor’s compact derived state, the
selected search artifact, and report construction rather than by the sum of all
committed payload sizes.

The report establishes only what these three named checks observed within the
declared target-local scope. It does not establish deployment behavior,
accessibility, prose quality, universal reproducibility, or correctness of an
omitted projection. Rendered-search `path` values are target-relative rather
than public URLs, and IR, RAG, Context, and other non-HTML artifacts are not
location-verified by this report unless a future contract explicitly adds a
URL-bearing field and a named check.
