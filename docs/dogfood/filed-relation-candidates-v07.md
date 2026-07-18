# Filed.fyi relationship-candidate dogfood

**Date:** 2026-07-18

**Boris commit:** `3450a3c` (merged PR #166)

**Source:** `drawmeanelephant/filed.fyi` at
`d3f40ccff23764690990a8b29fa94385eb95f0ea`

**Mode:** read-only Starlight migration lab, `--max-pages=200`

## Outcome

The first v0.7 relationship-candidate slice works against the real Filed.fyi
content shape. Two isolated runs selected the same 200 source pages, generated
204 compilable Boris pages (including synthetic trunks), and produced
byte-identical artifacts after excluding the run-path-bearing
`compile_report.json`. The source checkout remained clean.

This is review evidence, not automatic relationship migration. The lab did not
write `relations:` into generated Markdown and did not change Boris core or IR.

## Measured results

| Measure | Result |
|---|---:|
| Source candidates inventoried | 567 |
| Source pages selected | 200 |
| Generated Boris pages | 204 |
| Pages with relationship evidence | 195 |
| Relationship values retained | 1,370 |
| Resolved `relates_to` proposals | 182 |
| Unique in-bound proposals | 179 |
| Duplicate proposals retained for review | 3 |
| Pages exceeding the 16-relation product bound | 0 |
| Highest proposal count on one page | 11 |
| Repeated-run output | byte-identical |
| Boris compile | pass |
| Source checkout after both runs | clean |

### Values by source field

| Field | Values |
|---|---:|
| `relatedEntries` | 639 |
| `relatedHaiku` | 158 |
| `relatedLimerick` | 155 |
| `mascotRef` | 144 |
| `concepts` | 154 |
| `escalationPath` | 108 |
| `relatedLorelog` | 12 |

### Review outcomes

| Outcome or reason | Values |
|---|---:|
| Resolved against converted entity map | 182 |
| Target not in converted entity map | 611 |
| Review-only field with no invented relation kind | 215 |
| Non-scalar or ambiguous object | 309 |
| Non-scalar value | 27 |
| Malformed inline list | 20 |
| Empty value | 4 |
| Duplicate product relation | 3 |
| Malformed or non-target scalar | 2 |

The counts intentionally overlap by category only where the sidecar's policy
distinguishes target resolution from review reason. The authoritative rows are
in generated `relation_candidates.json`, not this narrative summary.

## Interpretation

### Confirmed behavior

- The allowlisted Filed-shaped fields are retained with source path, source
  line, raw value, normalized target when safe, and an explicit decision.
- A `relates_to` proposal appears only when a target-like value resolves in the
  converted entity map.
- Duplicate proposals remain visible without consuming another relation slot.
- `concepts` and `escalationPath` remain review-only; the lab does not invent
  taxonomic or workflow semantics.
- Malformed, nested, empty, and unresolved values remain evidence instead of
  disappearing.

### Documented evidence boundary

The lab deliberately converts at most 200 pages and resolves targets only
against that converted entity map. Filed.fyi has 367 additional candidates
outside this run. Therefore the 611 unresolved values mean **not resolved in
this bounded conversion**, not necessarily missing from the whole source site.
Site-wide target discovery, if added later, must preserve whether a target was
selected, merely inventoried, ambiguous, or actually absent.

This boundary is the main follow-up revealed by dogfood. It is not a reason to
raise the conversion cap or silently emit relationships.

### Independent source-side census

A separate read-only census inspected 2,263 Markdown/MDX files across the
source repository, including content outside the migration lab's discovered
567-page docs root. It did not reuse `relation_candidates.json`, so its totals
are an independent shape check rather than a direct comparison with the bounded
200-page run.

The census found:

- 1,059 `relatedEntries` values: 1,055 `{collection, id}` objects and four
  scalars; 1,025 conservatively resolve uniquely source-wide.
- All 158 `relatedHaiku` and all 155 `relatedLimerick` values use `{slug}`
  objects and resolve uniquely source-wide. The current lab preserves these but
  classifies them as `non_scalar_or_ambiguous_object`; recognizing this closed
  object shape is a concrete follow-up.
- `mascotRef` is genuinely risky as a bare identifier: only 155 of 640 scalar
  values resolve uniquely, while 442 are ambiguous across mascot and derivative
  pages and 43 lack a page match.
- `concepts` is predominantly taxonomy-like text and `escalationPath` is prose;
  keeping both review-only is supported by the source evidence.
- No conservative exact self-targets were found. Three repeated values occurred
  across two pages, all under `concepts`.

The independent pass left the source checkout unchanged and found no YAML parse
failures in 2,255 files with leading frontmatter.

## Reproduction

```bash
zig build
zig build --build-file tools/migration-lab/build.zig

./tools/migration-lab/zig-out/bin/boris-migration-lab \
  --mode=starlight \
  --root=/tmp/filed.fyi \
  --out=/tmp/boris-v07-filed-relations-dogfood-a \
  --max-pages=200 \
  --boris=./zig-out/bin/boris

./tools/migration-lab/zig-out/bin/boris-migration-lab \
  --mode=starlight \
  --root=/tmp/filed.fyi \
  --out=/tmp/boris-v07-filed-relations-dogfood-b \
  --max-pages=200 \
  --boris=./zig-out/bin/boris

diff -rq -x compile_report.json \
  /tmp/boris-v07-filed-relations-dogfood-a \
  /tmp/boris-v07-filed-relations-dogfood-b

git -C /tmp/filed.fyi status --short
```

## Recommendation

Keep relationship migration review-first. The next bounded engineering cards
are: (1) recognize the proven `{slug}` object shape for `relatedHaiku` and
`relatedLimerick`; then (2) add an inventory-only whole-site target index with
explicit `selected`, `inventoried`, `ambiguous`, and `absent` outcomes. Do not
emit product `relations` until a human or an explicit checked-in mapping policy
promotes a candidate.
