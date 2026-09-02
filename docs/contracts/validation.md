# Authoritative no-publication validation

**Status:** normative and implemented on the v0.8 afterparty line

**Version:** Boris/0.8.2; no IR schema change

This contract defines the source/compiler-validity command:

```text
boris validate [HTML source and target options]
```

`validate` answers one bounded question: would the selected HTML input and
configuration survive Boris's canonical prepublication compiler phases? It
does not publish a site or create a second implementation of Boris validity.

## Authority rule

Boris compiler modules remain the sole authorities for discovery, source
identity, frontmatter, graph topology, semantic relations, dependencies,
registered components, layouts, themes, assets, and selected-target
configuration. `validate` must call those implementations in process. It must
not reproduce their rules with regexes, a second parser, a script policy layer,
or a subprocess build.

Repository scripts may orchestrate `boris validate`, inspect its exit status,
and assert contracted diagnostic codes. They must not independently decide
whether Boris source is valid. No generated ID map, manifest, lockfile,
registry, or other authority file is part of this command.

## CLI surface

With no target selector, `validate` uses the normal synthetic target named
`default`, output path `dist/`, and default layout. The output path participates
in target-isolation checks but is not created or changed.

The command accepts the existing HTML vocabulary where applicable:

- `--input DIR` and the explicit `--textile` input-family adapter;
- `--html`, `--html-dir DIR`, and repeatable `--target NAME=DIR`;
- `--html-layout PATH`, `--theme ROOT`, `--target-layout NAME=PATH`, and
  `--layout-rule TARGET SELECTOR PATH`;
- `--sitemap`, `--sitemap-path PATH`, and their required `--site-url URL`;
- `--quiet`, `--help`, and `--report PATH` (the HTML-path diagnostics
  report, `html-build-report-0.2.0`; see
  [`diagnostics.md`](diagnostics.md#html-path-machine-readable-report));
- `--watch` (issue #647): the zero-write validation daemon. `validate --watch`
  repeats the preflight on every debounced change using the same watch
  coordinator, coalescing, ignore rules, and signal handling as HTML watch
  mode ([`watch-mode.md`](watch-mode.md)). `--watch-json` carries each cycle
  on the NDJSON event stream with `mode` `"validate"` and `pages_written`
  `null`; `--report PATH` is rewritten (replacement, never append) every
  cycle. `--incremental` is implied by `--watch` in `Options` but the
  validate action forces it off internally (validation never writes
  fingerprints). The daemon exits `0` on SIGINT/SIGTERM.

It deliberately rejects:

- publication/export selectors: `--out`, `--no-rag`, RAG, Context Bundle,
  `llms.txt`, and RSS options;
- publication execution controls: `--incremental` (standalone; implied by
  `--watch`) and `--jobs`;
- Documentation Intelligence analysis controls: `--format`;
- `--html-dir`, `--target`, `--serve`, and `--port` **with `--watch`**: the
  daemon always preflights the single synthetic `default` target and writes
  no output, so output/selection flags would silently select nothing;
- publication-profile selection, which belongs to `plan` and any future
  profile consumer.

RSS, IR, RAG, Context Bundle, and `llms.txt` are distinct projections, not HTML
target configuration. This first command slice does not silently select or
validate those projections. Sitemap is different: it is configuration owned
by one selected HTML target, so its URL/path rules are applicable here.

## Canonical phase boundary

Normal HTML compilation and `validate` share the coordinator and authorities,
then use the same render helper on different sides of the publication branch:

```text
target + sitemap configuration
→ source discovery and input-family checks
→ frontmatter parse and PageDb promotion
→ identity, graph topology, semantic-relation validation, and graph freeze
→ include/wiki dependency resolution
→ layout selection and loading
→ theme/footer and content-local asset inventory
                         ├─ validate: heading harvest → shared page render/slot
                         │  preparation → in-memory output link audit over the
                         │  assembled page bytes → in-memory sitemap render →
                         │  discard all bytes and return
                         └─ build: create target/stage → heading/fingerprint work
                            → shared page render/slot preparation + writes
                            → sitemap/search/audit/commit/cache/evidence
```

The implementation ownership at the boundary is:

| Validity phase | Canonical owner reused by build and validate |
|---|---|
| Target names, output isolation, workspace containment, and target/layout collisions | `target.validateTargets` and layout-selection helpers |
| Sitemap path, site URL, duplicate URL, count, and byte limits | shared sitemap configuration and renderer |
| Discovery, source paths, input family, frontmatter, IDs, and PageDb promotion | scanner/parser and `compile.loadAndPromoteFormat` |
| Duplicate IDs, parent topology, cycles, roles, and semantic relations | shared `graph` validators used before freeze |
| Includes, wiki targets, and dependency indexes | `SharedCompileState` and the normal dependency resolvers |
| Heading IDs and wiki fragments | the normal Oliver heading-harvest path |
| Registered components, Markdown/Oliver rendering, graph chrome, TOC, metadata, footer, and rewritten asset URLs | the shared per-page render/slot helper |
| Layout markers/rules, theme files, and content-local asset safety | normal layout, theme, and content-asset loaders |

Diagnostic ordering is the normal canonical ordering. Target plans and layout
rules retain their existing canonical sorting. Multi-target validation performs
the same shared discovery/freeze once and applies the prepublication path to
each selected target; it publishes none of them even when all pass.

## Why bounded rendering is included

Some source validity is established only while preparing rendered HTML:
heading IDs used by wiki fragments, component expansion, render failures, layout
slots, footer content, and content-asset URL rewriting all live on that path.
`validate` therefore renders pages into its normal per-page in-memory arena and
discards the prepared slots. Sitemap bytes are likewise rendered in memory and
discarded so its exact size/count/URL rules cannot drift from `build`.

Because the rendered HTML exists in memory anyway, `validate` also runs the
same output link audit as `build`, over the exact assembled page bytes (the
same render helper and layout splice) against the intended output set: every
page plus published content, theme, and sitemap assets. `EROUTEMISSING`,
`EROUTEESCAPE`, and `EPUBLICATIONLOCATION` therefore fail validation exactly
as they fail compilation — without a target or stage directory ever appearing.
The audit's diagnostics are the shared `build`/`validate` diagnostic form,
emitted by the same reporter.

This is not a temporary-directory build. Validation returns before the first
target or sibling stage directory is created.

## Filesystem and output contract

On success or failure, `validate` must not create, replace, remove, or scrub:

- the selected HTML target or `{target}.boris-stage`;
- HTML pages, copied assets, sitemap, or rendered-search data;
- `.boris-cache` state;
- IR, RAG, Context Bundle, `llms.txt`, or RSS artifacts;
- `artifacts.json`, `checks.json`, `claims.json`, `touches.json`, Proof Pack
  files, or any other publication evidence;
- a semantic authority file.

The optional `--report PATH` file is the one deliberate exception: it writes
the shared HTML-path diagnostics report. Under `--watch`, every cycle repeats
this contract — each rebuild re-runs the preflight and writes nothing except
that report, which is replaced (never appended) per cycle so a consumer never
reads stale failure state.

Target path validation may observe path metadata for the same no-follow and
isolation rules used by a later build. Existing target contents remain
untouched. Source, layout, theme, or asset reads are not filesystem mutations.

## Diagnostics and exits

`validate` uses the shared diagnostic categories, source loci, remediation
text, sorting, stderr text form, and process exit classes from
[`diagnostics.md`](diagnostics.md):

| Exit | Meaning |
|---:|---|
| `0` | Every applicable selected-target prepublication phase passed |
| `1` | Content, graph, dependency, component, layout, theme, asset, or bounded-render validity failed |
| `2` | CLI or target/configuration usage failed |
| `3` | Filesystem, allocation, or unexpected system failure |

Non-quiet success writes only a progress line to stderr; stdout remains
reserved. `--quiet` suppresses progress and diagnostic stderr without changing
the exit code. `validate` rejects `--format`, which belongs to Documentation
Intelligence analysis, and must not misuse the Documentation Intelligence
schema or write IR `build-report.json`; `--report PATH` (one-shot or under
`--watch`) writes the HTML-path diagnostics report
(`html-build-report-0.2.0`), never a semantic authority file. Under `--watch`
the daemon keeps running across recoverable failures and exits `0` on
SIGINT/SIGTERM (same policy as HTML watch mode).

## Distinction from adjacent commands

| Surface | Question answered | Additional policy or evidence | Writes |
|---|---|---|---|
| `validate` | Does selected HTML source/configuration survive canonical prepublication compilation? | None | None |
| `check` | What graph/dependency health facts and first-slice unreferenced-page findings exist after a valid frozen graph? | Documentation Intelligence policy | Optional explicit report only |
| normal `build` | Can Boris preflight, render, stage, commit, and emit the selected publication/projection? | Publication and projection semantics | Selected product artifacts |
| publication evidence | What can be proven about exact committed target bytes? | Inventory, checks, claims, Touch Atlas, and Proof Pack contracts | Target-local evidence after commit |
| proposed `doctor` | Does an existing publication snapshot agree with source/profile/rendered-artifact expectations? | Internal kernel in `src/doctor.zig`; no public command | Optional report only, if a command lands |

`check` is not an alias: it uses a validated graph to run analysis policy and
does not validate HTML layouts, themes, content assets, or the complete HTML
render path. Doctor is an internal snapshot kernel (`src/doctor.zig`) and is
neither a public command nor folded into `validate`.

## Deliberate exclusions

The following require committed/staged output, an existing deployment, or a
separate policy contract and are not source validity:

- rendered-search artifact generation (the search index is a written
  projection, not a validity question; the output link audit itself runs
  in memory during validation);
- cache reuse, parallel worker behavior, watch recovery, and commit atomicity;
- artifact inventory, publication checks, claims, Touch Atlas, and Proof Pack;
- deployed URLs, network behavior, redirects, HTTP metadata, or indexing;
- accessibility compliance, prose/editorial quality, SEO scores, or LLM review;
- auto-fix, source mutation, generated IDs, or bookkeeping registries.

A passing validation does not promise that a later build cannot fail during an
output write, commit, publication-evidence phase, or after inputs change. It
means only that the observed input survived the shared prepublication authority
defined above.

## Environment notes

- Generated directories (`dist/`, `rag/`, `source-rag/`, `.boris-cache/`, and
  temporary release-gate output) are not source-of-truth or review currency.
- Symlink-related tests may be skipped on hosts that deny symlink creation;
  the no-follow and symlink-rejection policy itself remains normative (see
  [html-output.md](html-output.md) § Symlink safety).
- Default HTML assumes trusted author input because raw HTML passes through
  unchanged per [oliver-renderer.md](oliver-renderer.md).

## Acceptance

The shipped contract tests must cover valid and repeated runs, canonical
frontmatter/ID/parent/relation/include/wiki/component failures, layout and
target configuration, duplicate-ID diagnostic parity with normal compilation,
absence of new or mutated target/evidence trees, and a validation-pass followed
by a successful normal build. For `validate --watch`, the black-box contract
script (`scripts/test-watch-json-contract.sh`) must cover the initial and
rebuild cycles emitting `mode` `"validate"` with `pages_written` `null`,
recoverable `build-failed` events that keep the daemon alive, and a
`--report` file rewritten per cycle with no output tree ever appearing.
