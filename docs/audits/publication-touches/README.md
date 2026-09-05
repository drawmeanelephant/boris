# Publication Touch Atlas examples

**Status:** implemented and shipped — Boris emits `_boris/proof/touches.json`
on every build.

These JSON files are hand-checkable examples for the
[`publication-touches.md`](../../contracts/publication-touches.md) schema.
They are illustrative evidence snapshots, not compiler output.

Each example contains only the three report bindings, copied metadata, and
edges derivable from those bindings. The input digests are fixed illustrative
values; the compiler's own reports carry SHA-256 digests of the exact
committed report bytes.

## Expected counts

The node count is `1 target + artifact count + 3 checks + finding count + 3
claims + 6 limitations`. Edge counts below are grouped by the contract's
canonical edge order.

| Example | Artifact / check / finding / claim / limitation counts | Nodes | Edges: owns / subject / supports / findings / claims / limits | Total edges |
|---|---:|---:|---:|---:|
| [`clean.json`](examples/clean.json) | 2 / 3 / 0 / 3 / 6 | 15 | 2 / 4 / 3 / 0 / 3 / 16 | 28 |
| [`failed-checks.json`](examples/failed-checks.json) | 5 / 3 / 3 / 3 / 6 | 21 | 5 / 7 / 6 / 3 / 3 / 16 | 40 |
| [`search-not-applicable.json`](examples/search-not-applicable.json) | 2 / 3 / 0 / 3 / 6 | 15 | 2 / 3 / 3 / 0 / 3 / 16 | 27 |

Supporting edges follow the shipped selector semantics: the declared
supporting scope of `rendered-html` is every committed artifact, and the
declared supporting scope of `rendered-search` is every committed `html-page`
record (the selector vocabulary carries statuses and kinds only, with no
advertised dimension). In the failed example, the fifth artifact is
`omitted-by-plan`: it receives a `target-owns-artifact` edge but not an
artifact-to-check edge. The finding
subjects intentionally do not gain finding-to-artifact edges; v1 forbids
inferring that lineage from a path-like diagnostic subject.

## Validation

Validate all three examples against
[`publication-touches-1.schema.json`](../../contracts/schemas/publication-touches-1.schema.json)
with a Draft 2020-12 JSON Schema validator. Schema validation covers object
shape, constants, enums, metadata, digest syntax, stable IDs, and edge
direction. It does not prove exact report bytes, target equality, canonical
ordering, selector membership, offsets, uniqueness, or cross-report
referential integrity; the runtime derives those when a proof pack binds the
reports, and its tests pin them.
