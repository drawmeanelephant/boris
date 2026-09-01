---
published_at: 2026-08-12T00:00:00Z
summary: Oliver's conformance gate binds to the exact official CommonMark 0.31.2 spec.txt, not merely to parseable examples.
---

# CommonMark conformance expectations

Oliver's conformance gate is bound to the exact official CommonMark 0.31.2
`spec.txt`, not merely to a file that happens to contain parseable examples.
The identity recorded in `tools/commonmark_expectations.zig` is:

- source: <https://spec.commonmark.org/0.31.2/spec.txt>
- bytes: `204857`
- normative examples: `652`
- SHA-256:
  `bfef4ddc97276b6ab6c2a28ace48478e35b1c50e60cde9f517ab8ab030aa3b82`

The harness rejects a different digest or byte/example count before running
Oliver. It also rejects malformed example fences, missing input/output
separators, nested example openings, empty section headings, and truncated
examples. The official corpus is downloaded for development and CI; it is not
vendored into the library or read by Oliver's filesystem-free core.

## Expectation classes

`tools/commonmark_expectations.zig` is a sorted, complete, nonoverlapping
partition of official example numbers:

- **supported** — Oliver must produce the normative HTML. A failure is a
  regression.
- **not-yet** — Oliver is known not to produce the normative HTML. A new pass
  is an expectation mismatch, not a silent score increase; it must be reviewed
  and moved to `supported`.
- **divergence** — Oliver deliberately differs from CommonMark. Each entry has
  a name, repository rationale, and exact pinned Oliver output. Conforming or
  changing to some third output both require review.

The partition is now **652 supported, 0 not-yet, and 0 named
divergences** — full conformance with the 0.31.2 corpus. The §2.5 entity
and numeric character references section is complete (named entities via
the WHATWG entities table, numeric references per §2.5's digit/code-point
rules), which also moved the entity-dependent link destination/title,
backslash-escape, and link examples to `supported`. HTML blocks §4.6 is
44/44: types 1–5 (script/pre/style/textarea element blocks, comments,
PIs, declarations, and CDATA, ending at their matching terminators)
joined types 6 and 7, which also flipped the two Lists examples that
embed `<!-- -->` comments in list items (spec examples 308–309). The
last not-yet example — the §4.7 link-reference-definition edge case 201,
`[foo]: <bar>(baz)` (an angle destination directly followed by a
would-be title is not a definition) — was closed by the
full-conformance milestone. The former
divergence — example 646, the recorded ATX trailing-backslash choice in
`docs/FEATURE-MATRIX.md` ambiguity 10 — was resolved to the normative
output by the thematic-break/Setext milestone: both example 644 and
example 646 now render the literal trailing backslash and were moved to
`supported`. The `divergences` table is empty by design; a future
deliberate divergence must add a named record with its rationale and exact
pinned Oliver output, and the expectation tests pin the current partition.

The classified `--gate` fails on any supported regression, unexpected not-yet
pass, or changed divergence. Report mode prints the same mismatches but exits
successfully and retains the classified normative-failure details, which is
useful while investigating. `--section` is report-only
and cannot be combined with `--gate`, because a partial run cannot validate the
complete manifest.

## Updating expectations

Expectation changes are reviewed product changes, not regenerated snapshots:

1. Run the official corpus and inspect every mismatch.
2. For an unexpected pass, verify the normative HTML and the corresponding
   feature tests, then move only that example/range from `not_yet` to
   `supported`.
3. Fix a supported regression rather than weakening its class.
4. Change a divergence only alongside its named rationale and exact pinned
   Oliver output. Do not edit the official expected HTML.
5. Keep ranges sorted and adjacent. The synthetic tests reject gaps, overlaps,
   out-of-range entries, unnamed divergences, and duplicate divergence records.

A CommonMark version upgrade is a separate migration: update the URL, byte
count, example count, digest, and the entire reviewed partition together.

## Acceptance commands

```bash
curl --fail --location \
  https://spec.commonmark.org/0.31.2/spec.txt \
  --output /tmp/commonmark-0.31.2-spec.txt

printf '%s  %s\n' \
  bfef4ddc97276b6ab6c2a28ace48478e35b1c50e60cde9f517ab8ab030aa3b82 \
  /tmp/commonmark-0.31.2-spec.txt | shasum -a 256 --check

zig build spec-conformance-test --summary all
zig build spec-conformance -- /tmp/commonmark-0.31.2-spec.txt --gate
zig build test --summary all
zig fmt --check build.zig build.zig.zon src tests tools
```

For a focused scorecard while developing, use an exact specification heading:

```bash
zig build spec-conformance -- /tmp/commonmark-0.31.2-spec.txt \
  --section "List items"
```
