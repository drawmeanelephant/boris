# `boris-testdata`

`boris-testdata` is a Zig companion binary that makes fixtures for Boris to
consume. It is a fixture generator, not a second compiler and not a test
runner framework. The useful output is a deterministic project tree that can
feed many later tests, scale runs, migration probes, and theme comparisons.

Build it from this directory with Zig 0.16:

```bash
zig build
zig build test
```

Generate, inspect, validate, and run a fixture:

```bash
zig build run -- generate \
  --pages 24 \
  --seed 20260801 \
  --profile readme-realistic-v1 \
  --output /private/tmp/boris-case

zig build run -- validate --fixture /private/tmp/boris-case
zig build run -- inspect --input /private/tmp/boris-case --format json
zig build run -- run --fixture /private/tmp/boris-case --boris /path/to/boris
zig build run -- republish-clean --fixture /private/tmp/boris-case --boris /path/to/boris
```

`generate` refuses to overwrite an existing directory unless `--force` is
present. It only deletes the exact output directory named by the user.

## Fixture contract

Every generated fixture has this shape:

```text
fixture/
  content/                    # Markdown pages and includes/
  optional-assets/            # sidecar assets for fixture cases
  optional-theme/             # copied or built-in Boris theme
  manifest.json               # boris-testdata/2
  files.jsonl                 # one deterministic inventory row per input file
  expected.json               # run expectation and barb assignments
  results/                    # Boris output, harness snapshots, and run evidence
    boris-output/             # baseline output, optionally poisoned after publish
    output-snapshot.jsonl     # full-tree harness snapshot; non-normative
    output-snapshot.json      # snapshot summary; not an ownership declaration
    run.json                  # subprocess and output evidence
    republish-clean-output/   # clean comparison publication from valid source
    republish-clean.json     # clean-comparison evidence
```

`manifest.json` key order is fixed. Its `files` entry records the JSONL count,
byte total, and SHA-256. `expected.json` records the expected Boris exit code,
the profile seed, and each barb's target page index. `files.jsonl` is emitted as
pages are written; it is never built as one corpus-sized in-memory string.

The input-file inventory deliberately excludes `manifest.json`,
`expected.json`, and `files.jsonl` themselves to avoid a circular hash. It
includes pages, include fragments, content-local assets, and theme files.
After a successful Boris run, `_boris/proof/artifacts.json` is the authoritative
Boris-owned artifact inventory. Artifact barbs select their path, kind, byte
count, and SHA-256 from that inventory, then mutate the output while leaving the
inventory unchanged. `results/output-snapshot.jsonl` is a full-tree harness
snapshot of the resulting output; it is explicitly non-normative and does not
declare ownership. `deployment_owned_extra` is therefore absent from
`artifacts.json` while still appearing in the snapshot.

`republish-clean` publishes the same valid source into a clean comparison tree.
It does not edit or automatically repair the poisoned output tree.

## Profiles, themes, and templates

Built-in profiles are:

| Profile | Purpose |
|---|---|
| `readme-realistic-v1` | README-shaped valid pages with Trunk/Satellite graph edges, links, includes, headings, tables, code fences, and an asset. |
| `nightmare-v1` | The same valid grammar with named failure barbs applied at deterministic loci. |
| `preserved-edge-v1` | Traversal-like Markdown links that Boris should preserve literally. |
| `mild-poison-v1` | Mostly valid output with one precise post-publish barb per selected case. |

Profiles are JSON references under `profiles/` and can also be supplied by
path. The closed profile shape is:

```json
{
  "schemaVersion": "boris-testdata-profile/1",
  "name": "my-profile",
  "description": "...",
  "style": "readme | reference | compact",
  "includeAssets": true,
  "barbs": ["duplicate_id"]
}
```

`--theme PATH` recursively copies a regular-file theme into
`optional-theme/`, sorting paths bytewise and rejecting symlinks. This is the
same command surface for the checked-in ideal/terminal themes and an external
source theme. Without the flag, the generator emits the built-in ideal theme.

`--template PATH` loads one external Markdown source template (bounded to 1 MiB),
expands only `{{id}}`, `{{title}}`, `{{parent}}`, `{{related}}`, `{{include}}`,
`{{index}}`, and `{{seed}}`, then parses the result into the same typed AST as
synthetic pages. Unknown tokens remain literal.

## Determinism and memory

The seed strategy is a SplitMix-style 64-bit mixer:

```text
pageSeed = mix(seed, pageIndex)
barbTarget = mix(seed, barbOrdinal + 1) mod pageCount
```

Graph identity is derived from page index and topology, not from filesystem
enumeration. Page paths, IDs, parent indices, JSON key order, inventory order,
and hashes are stable for the same options and source bytes. `run` records
timing separately because timing is intentionally not deterministic.

The generator retains only a compact `PagePlan` array (`kind`, guide/article
ordinals, parent index, and seed). It creates one page AST and one page byte
buffer at a time, streams each inventory row immediately, and releases the
page arena before continuing. `--pages` is an exact workload parameter; it is
not part of a named workload identity. Positive `usize` page counts are accepted;
checked planning and ordinary allocator/filesystem errors report workload limits
honestly instead of imposing a named corpus ceiling.

## Barb taxonomy

Barbs mutate a valid baseline at a precise locus. Pass `--barb NAME` more than
once to override a profile's list.

| Barb | Expected behavior |
|---|---|
| `duplicate_id`, `self_parent`, `missing_parent`, `parent_cycle` | Boris content/graph failure |
| `unknown_frontmatter`, `legacy_parent_key`, `malformed_frontmatter`, `duplicate_frontmatter_key` | Boris frontmatter failure |
| `broken_wikilink`, `missing_include`, `include_cycle`, `missing_heading_fragment` | Boris dependency failure |
| `invalid_utf8` | Boris encoding failure |
| `unsafe_markdown_link` | Preserved literal; expected successful build |
| `invalid_theme` | Theme/layout failure |
| `html_missing_local_route` | Post-publish `HTML_LOCAL_ROUTE_MISSING` finding |
| `html_missing_fragment` | Post-publish `HTML_FRAGMENT_MISSING` finding |
| `html_duplicate_id` | Post-publish `HTML_DUPLICATE_ID` finding |
| `html_unclosed_structure` | Post-publish `HTML_MALFORMED` finding |
| `artifact_missing` | Deletes one canonical inventoried output artifact after baseline |
| `artifact_digest_mismatch` | Changes one canonical artifact byte without updating `artifacts.json` |
| `search_stale_title` | Changes one search title without regenerating search |
| `deployment_owned_extra` | Adds an unrecorded deployment file; expected no finding |

These names are not random fuzz labels: they are the stable join key between
the fixture, `expected.json`, the canonical artifact inventory, and future result
comparison tooling. Each assignment also records its expected finding code,
coverage state, and clean comparison publication. Post-publish barbs are applied by `run`
only after Boris has successfully emitted the output tree, so they do not
masquerade as source or compiler failures.

## Boris evidence

`run` invokes the supplied Boris binary as a subprocess only because it is an
evidence collector; it never uses a subprocess to generate Markdown. The
`boris-testdata-run/3` record at `results/run.json` includes:

- expected and actual exit codes plus a pass/fail comparison;
- elapsed nanoseconds;
- the Boris binary SHA-256;
- deterministic baseline and poisoned output-tree SHA-256 values over sorted relative paths and bytes;
- the canonical artifact-inventory SHA-256 and selected artifact path/kind/byte/digest facts;
- the non-normative full-tree output-snapshot hash and file count;
- output file count, stdout, and stderr.
