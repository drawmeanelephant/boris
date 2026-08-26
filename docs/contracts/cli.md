# Boris CLI contract

**Status:** normative command-routing contract for the v0.8 afterparty line.

Boris exposes the stable top-level commands below. A missing command is
equivalent to `build` for backwards compatibility. The `standard-site`
family is an additional explicit network family, not a build mode.

```text
boris build [build options]
boris validate [HTML source and target options]
boris check [--input DIR] [--format human|json] [--report PATH] [--fail-on-unreferenced]
boris impact ID [--input DIR] [--format human|json] [--report PATH]
boris watch [build options]
boris plan --profile PATH [plan overrides]
boris recipe-scale --input DIR --id PAGE (--factor TEXT | --servings N) [--cooklang] [--out PATH]
```

## Commands

| Command | Purpose | Writes by default |
|---------|---------|-------------------|
| `build` | Compile the configured site or explicitly selected export | HTML `dist/`, or the selected `--out`, `--rag-dir`, `--context-dir`, `--llms`, or `--rss` path |
| `validate` | Run the selected HTML input/configuration through the canonical prepublication compiler phases | Nothing; `--report PATH` writes the HTML-path diagnostics JSON |
| `check` | Validate the frozen graph and emit a deterministic health report | Nothing unless `--report` is supplied |
| `impact ID` | Emit the transitive dependents of a page or source endpoint | Nothing unless `--report` is supplied |
| `watch` | Run an HTML build, then rebuild after debounced source/layout changes | HTML output selected by build options |
| `plan` | Parse and normalize one publication profile without executing it | Nothing; normalized declaration JSON is written to stdout |
| `standard-site <subcommand>` | Explicit Standard.site family (plan / records / verify / login / sessions / logout / publish / smoke) | Plan/records/verify/publish-evidence/smoke artifacts on stdout or `--out PATH`; login writes a `0600` session document under the session root |
| `nostr plan` | Emit the offline NIP-23 publication plan for the selected profile (no key, no signature, no relay) | Nothing; plan JSON on stdout |
| `nostr sign` | Sign a plan artifact into a signed-event bundle; the key is read once from stdin (hex or nsec) and never from argv/profile/env | Nothing; bundle JSON on stdout or `--out PATH` |
| `nostr publish` | Send the exact signed events from a bundle to the plan's relays over RFC-6455 WebSocket (no key; the bundle was signed offline). Every relay interaction is bounded and produces per-relay evidence; the run always reaches a `complete`/`partial`/`failed`/`incomplete` verdict | Nothing; the report JSON on stdout or `--out PATH` |
| `recipe-scale` | Compile the selected tree and print a derived Cooklang scale view for one page | Nothing; view JSON on stdout or `--out PATH`. Never rewrites `.cook` or `graph.json` |

`boris standard-site` with no subcommand is a usage error (exit 2) that
prints the family list, not the full compiler help. `boris standard-site
--help` / `-h` prints the same family list and exits 0. First testers
should start at the non-normative [operator path](../standard-site.md).
Against bsky.social the working live path is
`login --app-password`; browser OAuth requests granular `repo:` scopes and the
live smoke verifies the grant. `smoke` accepts `--did` or
`--handle`. See [standard-site.md](standard-site.md),
[atproto-sessions.md](atproto-sessions.md), and
[atproto-live-smoke.md](atproto-live-smoke.md).

`watch` is the command spelling for local development. The existing
`build --watch` / bare `--watch` form remains accepted as a compatibility alias
and has identical behavior. Watch is HTML-only and implies incremental mode.

`boris validate --watch` is the zero-write validation daemon (issue #647): the
same debounced coordinator re-runs the `validate` preflight on every change,
writes nothing except the optional `--report` file (replaced each cycle), emits
`--watch-json` events with `mode` `"validate"` and `pages_written` `null`, and
exits `0` on SIGINT/SIGTERM. `--html-dir`, `--target`, `--serve`, and `--port`
are usage errors with it; see the
[validation contract](validation.md) and
[watch-mode contract](watch-mode.md).

### Local preview (`watch --serve`)

`boris watch --serve [--port N]` serves the built HTML tree over loopback HTTP
on `127.0.0.1` (default port `8090`; `--port 0` selects an ephemeral port). It
reuses the watch coordinator — the same debounced rebuild cycle — and pushes an
SSE `reload` event to connected clients after every successful rebuild.

Served routes:

| Route | Behavior |
|-------|----------|
| `/` | Static files under the built output directory (`index.html` for the root; directory-style targets fall back to `index.html` under the prefix) |
| `/__boris/` | Helper page (site iframe + EventSource) that auto-reloads the preview after each successful rebuild |
| `/__boris/events` | SSE stream; `event: reload` with a generation counter `data` payload on each successful rebuild |

Boundaries: loopback-only, static file serving (no HMR, CSS injection, or
build-time script injection), and strictly no changes to artifacts,
diagnostics, or exit codes. The helper page and SSE stream are generated by the
server process, never written to the output directory. With multiple targets
the first (canonical-order) target's output directory is served and the URL is
printed on startup. `--serve` / `--port` require watch mode; `--port` implies
`--serve`.

`validate`, `check`, and `impact` are read-only, but they are not aliases.
`validate` covers the selected HTML source/configuration through the shared
prepublication render boundary. `check` and `impact` operate on a valid frozen
graph and add Documentation Intelligence analysis rather than layout/theme/HTML
preflight. See the normative [validation contract](validation.md).

`validate` does not create HTML, IR, RAG, context, RSS, cache, search, or
publication-evidence artifacts. It accepts applicable existing HTML options,
including target/layout/theme and sitemap configuration, and rejects export
selectors, `--incremental`, `--refresh-evidence`, `--jobs`, and `--format`; `--report PATH` writes
the shared `html-build-report-0.2.0` JSON (additive; see
[Machine-readable reports](#machine-readable-reports)). With `--watch` it
becomes the zero-write validation daemon described above. `check` and `impact`
likewise create no product artifacts; only their explicit `--report` path may
be written.

## Exit codes

| Code | Meaning |
|-----:|---------|
| `0` | Successful build, validation, plan, watch shutdown, valid impact query, or check with no enabled policy failure |
| `1` | Content/graph failure, or an opted-in `check` policy finding such as an unreferenced page |
| `2` | Usage error: unknown command/flag, missing value, invalid ID, or conflicting mode |
| `3` | I/O or system failure |

The command parser must reject unknown positional arguments and conflicting
mode flags before touching the content tree. `--help` exits `0` without reading
content or writing artifacts. `--version` / `-V` exit `0` printing the compiler
id (`pipeline.compiler_id`, e.g. `boris/0.8.1`) to stdout without reading
content or writing artifacts.

Usage diagnostics on the exit-2 path are self-attributing (issues #761 and
#764). When a value rejection has a parser-known flag — the layout/theme path
grammar shared by `--theme` and `--html-layout` — the diagnostic names that
flag with the grammar rule, never a different flag guessed by scanning argv.
When a conflicting-options rejection has one unambiguous offending pair, both
tokens are named as typed, e.g. `error: check conflicts with --theme`;
ambiguous multi-cause conflicts keep the generic `conflicting options (try
--help)` form. The `--help` conflict matrix lists the analyzer×HTML-selector
family and the HTML-selector×explicit-`--out` family alongside the rest.
Exit codes, exit-code classes, and accepted argv are unchanged by attribution;
the frontmatter `status:` enum semantics (draft renders but is excluded from
nav, search, sitemap, RSS, and publication projections) are stated in `--help`
and remain normative in [frontmatter.md](frontmatter.md).

The exit-2 path stays short (#777): each usage error prints its
self-attributing cause line plus one synopsis line (`usage: boris <command>
[options] …`) and nothing else — the full option help appears only on an
explicit `--help`. The `standard-site` family is the exception: its bare,
unknown-subcommand, missing-profile/identity, and conflicting-flag errors
print the subcommand-family list instead of the generic synopsis, as
specified above.

## stdout machine surface

stdout is a real machine surface, not a void. A closed set of commands and
flags emit one machine-readable document on stdout; everything else keeps
stdout empty, so a consumer can distinguish "stdout is empty by contract"
from "stdout is empty because nothing was requested". Progress, diagnostics
(text form), `--help`, and the human analysis summary stay on **stderr**.

The closed stdout-emitting set, with each entry's default document:

| Command / flag | stdout document |
|---|---|
| `--version` / `-V` | One line: the base compiler id |
| `--build-info` | One line: the `boris-build-info` provenance document (#776) |
| `--timings` | `boris-timings` JSON report (appended after the run, including failed runs) |
| `plan` | Normalized publication declaration JSON |
| `standard-site plan` | Standard.site plan JSON |
| `standard-site records` | Standard.site records JSON |
| `standard-site verify` | Standard.site verify result JSON |
| `standard-site publish` | Standard.site publish evidence JSON |
| `standard-site smoke` | Standard.site smoke result JSON |
| `nostr plan` | Offline NIP-23 plan JSON |
| `nostr sign` | Signed-event bundle JSON |
| `nostr publish` | Publish report JSON |
| `recipe-scale` | Derived Cooklang scale-view JSON |

Where a command defines `--out PATH`, that flag writes the same document to a
file instead of stdout; without `--out`, the document is stdout-only for that
command. `plan` is the exception: it always writes its single document to
stdout and rejects `--timings`, because its stdout is reserved for one JSON
document and no trailing timing report may be appended.

Everything not listed here — including `build`, `validate`, `check`, `impact`,
`watch`, `init`, `standard-site login|sessions|logout`, and all bare HTML/IR/
RAG/Context/llms/RSS/sitemap builds — leaves stdout empty. `check` and
`impact` without `--report` print the human or JSON analysis to **stderr**,
never stdout.

## Workspace containment

Every generated **output tree** — HTML (`--html-dir` / `--target`), IR
(`--out`), RAG (`--rag-dir`), context (`--context-dir`), and `llms.txt`
(`--llms-path`) — is confined to the **workspace**, defined as the process
current working directory. A misconfigured build can never clobber an
arbitrary tree outside the project. Output paths are resolved lexically
against the cwd and checked with a **path-component boundary**: the resolved
absolute path must equal the workspace or be `workspace/` + more (so `dist`
never matches `distribution/…`). A violation fails with `WorkspaceEscape`
(exit 2, usage class) before any content is read or artifact is written.

The containment rule is uniform across every output tree. Absolute output
paths are accepted when they resolve inside the workspace; relative paths
(including `..` segments that stay inside the workspace) are equivalent
spellings of the same destination. There is no exporter-specific absolute-path
rule: IR `--out /abs/path` behaves exactly like HTML `--html-dir /abs/path`.
Because the check is lexical, a spelling that does not match the workspace's
canonical path is rejected even when the filesystem would resolve it to the
same place — e.g. on macOS, where `/tmp` is a symlink to `/private/tmp`, an
absolute output under `/tmp/…` is `WorkspaceEscape` while the same directory
spelled `/private/tmp/…` is accepted.

| Case | Result |
|------|--------|
| `--html-dir`, `--target`, `--out`, `--rag-dir`, `--context-dir`, `--llms-path` pointing outside cwd | `WorkspaceEscape`, exit 2 |
| Relative output paths inside cwd (`--out ir`, `--out ./ir`, `--out ../x/ir` where `../x` is under cwd) | accepted |
| Absolute output paths resolving inside cwd (any exporter, `--target name=/abs/…` included) | accepted |
| The workspace root itself as an output tree (`--html-dir .`, `--out .`) | `TargetOutputCollision`, exit 2 |
| Output tree equal to or nested under the content root (`--out content`) | `TargetOutputCollision`, exit 2 |
| Output tree equal to or nested under another target, a declared layout, or its parent | `TargetOutputCollision`, exit 2 |
| `--report PATH` / `--analysis-report` (single files) | not constrained; any path the process may write |
| `--input PATH` (content root) | not constrained; `--input` names the source tree, not an output |

Single-file report flags (`--report` on `build`/`validate`, and
`check`/`impact --report`) are deliberately outside containment: they write
one explicit file, never a tree, so an absolute path is accepted as-is.
`--input` is likewise unconstrained: the compiler reads the content root but
never writes into it as an output tree (outputs that would land inside the
content root are `TargetOutputCollision`).

The same boundary and exit-2 mapping apply to `watch` (each watch target is
validated as an HTML target), and to the multi-target plan; the per-target
rules are specified in
[multi-target-isolated-output.md](multi-target-isolated-output.md).

## Machine-readable reports

Consumers should invoke:

```text
boris check --input CONTENT --format json --report REPORT.json
boris impact ID --input CONTENT --format json --report REPORT.json
```

`boris check` reports `unreferenced_page` findings without failing by default.
CI that treats those findings as fatal may add `--fail-on-unreferenced`; the
flag is rejected for other commands and does not change the report schema or
bytes.

These reports use the versioned `boris-documentation-intelligence` schema
defined in [`documentation-intelligence.md`](documentation-intelligence.md).
The report is deterministic for the same content bytes, relative paths,
compiler version, and host filesystem semantics. Arrays are sorted; it contains
no timestamps, hostnames, absolute source identities, or random IDs.

The existing compiler export remains a separate, richer artifact contract:
`build --out DIR` writes IR `manifest.json`, `graph.json`, `completion.json`,
and `build-report.json` under the versioned [`ir-schema.md`](ir-schema.md)
contract. `build-report.json` is authoritative for compiler diagnostics and
source locations; `graph.json` is authoritative for frozen nodes and edges;
`completion.json` is the deterministic editor completion surface (entity ids,
relation kinds, parent targets, layout slots). Nova and other editor
integrations must consume these published contracts rather than
reimplementing frontmatter or graph resolution.

The HTML path has its own machine-readable diagnostics report: `boris build
--report PATH` and `boris validate --report PATH` write a deterministic JSON
report on both success and failure (`html-build-report-0.2.0` schema, same
diagnostic-object shape as the IR report). It covers every HTML-path
diagnostic class — parse/graph, component, include, wiki-link, asset,
link-audit, and layout/theme — and is the surface the preview server and
editor consume. `--report` is rejected on `watch` and on non-HTML build modes;
`--format` remains analysis-only. See
[`diagnostics.md`](diagnostics.md#html-path-machine-readable-report).

### `--report` per mode

`--report PATH` has two meanings, one per command family:

| Command | What `--report PATH` writes | Without `--report` |
|---|---|---|
| `check` / `impact` | The Documentation Intelligence analysis report (human or JSON per `--format`) | The same report prints to **stderr** |
| `build` / `validate` | The HTML-path diagnostics report (`html-build-report-0.2.0` JSON) | No report file; diagnostics stay on stderr as text |

On `build`/`validate` the file is additive: stderr text and exit codes are
unchanged with or without it. On `check`/`impact` the file replaces the
stderr print of the report. `--report` is rejected on `watch` and on non-HTML
build modes (IR/RAG/Context/llms/RSS/sitemap).

## Version query

`boris --version` (or `boris -V`) prints the compiler id and exits `0` without
reading content or writing artifacts, short-circuiting exactly like `--help`
(invalid trailing flags are ignored; the first of `--version`/`--help` seen
wins). The output is exactly one line on **stdout**:

```text
boris/0.8.1
```

The id is `pipeline.compiler_id` (`src/pipeline.zig`): the base compiler id,
never suffixed. Artifacts record the base id, or a variant-suffixed id when
the corpus engages the Cooklang or semantic-relations stack — the IR
`manifest.json` (`compiler` field), the IR `build-report.json` (`compiler`
field, success and failure alike), and the editor `completion.json`
(`compiler_id` field) write e.g. `boris/0.8.1` for a Markdown corpus and
`boris/0.8.1+cooklang` for a Cooklang corpus. Scripts and CI can therefore
pin the compiler, and provenance checks must accept the base or a
`+`-suffixed artifact id:

```bash
# Pin: refuse to build with an unexpected compiler.
BORIS_VERSION="$(boris --version)"
[ "$BORIS_VERSION" = "boris/0.8.1" ] || exit 2

# Verify an artifact set's provenance: the recorded id is the base id,
# possibly suffixed for variant corpora (e.g. boris/0.8.1+cooklang).
ARTIFACT_ID="$(sed -n 's/.*"compiler": "\([^"]*\)".*/\1/p' .boris/manifest.json)"
case "$ARTIFACT_ID" in
  "$BORIS_VERSION" | "$BORIS_VERSION"+*) ;;  # base or variant-suffixed id
  *) echo "compiler mismatch: $ARTIFACT_ID" >&2; exit 2 ;;
esac
```

Treat all ids as opaque `name/version` text: compare them exactly rather than
substring-matching on the version portion, since suffixes are possible.

### Build info query (`--build-info`)

`boris --version` deliberately stays byte-stable across builds of the same
release, so it cannot distinguish two binaries compiled from different
commits (#776). `boris --build-info` is the additive provenance query: it
joins the `--help`/`--version` short-circuit family (invalid trailing flags
ignored; first flag seen wins; exits `0`, reads no content, writes no
artifacts) and prints exactly one JSON line on stdout:

```text
{"format": "boris-build-info", "schemaVersion": "1", "version": "boris/0.8.1", "vcsRevision": "a8ef247"}
```

`vcsRevision` is an opaque token baked in at compile time by `build.zig`
(auto-detected from git, overridable with `-Dvcs-revision=…`; a dirty
worktree appends `.dirty`; tarball builds without git carry `""`). It never
alters the compiler id, exit codes, or any artifact schema. The HTML-path
`--report` document mirrors the same token as its additive `vcsRevision`
field ([diagnostics.md](diagnostics.md#html-path-machine-readable-report)).

**Provenance carriers and the IR decision (#781).** Three further surfaces
copy the same token verbatim (with the `""` sentinel when undetected), each
as an additive field that no upstream digest covers:

- complete-mode RAG `catalog_meta.json` — trailing `vcs_revision`
  ([rag-export.md](rag-export.md#catalog_metajson-complete-mode-only));
- `boris-recipe-scale` view envelopes — `vcsRevision` after `compiler`
  ([cooklang-compatibility.md](cooklang-compatibility.md));
- publication Proof Packs — `vcs_revision` between `target` and `inputs`,
  mirrored in `_boris/proof/index.html`
  ([publication-proof-pack.md](publication-proof-pack.md));

The **IR artifact set** (`manifest.json`, `graph.json`, `completion.json`,
`build-report.json`) deliberately does not carry it — decision recorded for
#781. IR bytes are pinned by path-stability, packaging-determinism, and
evidence-chain goldens that exist precisely to catch unintended drift; they
must stay byte-stable for the same content regardless of worktree state. A
commit-varying field inside that set would break those guarantees at every
commit. Attribution for an IR compile remains binary-level: pair a given IR
artifact set with `--build-info`, `--version`, or the HTML-path `--report`.
Reversing this decision would require redesigning what the evidence chain
hashes, not a schema-field addition.

## Timing report (`--timings`)

`--timings` is an opt-in, observation-only flag accepted alongside any command
or mode that runs a compiler phase. When present, Boris appends one
machine-readable JSON report to **stdout** after the run — including failed
runs, where the report shows the phases that completed. It never changes
stderr diagnostics, exit codes, published artifacts, or `--quiet` semantics:
the option is off unless requested, and the report is never a source of truth
for correctness.

`plan` is the one exception: it runs no compiler phase, and its stdout is
reserved for the single normalized declaration JSON document, so
`plan --timings` is rejected as a conflicting-options usage error (exit 2)
rather than corrupting the plan stream with trailing data.

The report uses the versioned `boris-timings` schema:

```json
{
  "format": "boris-timings",
  "schemaVersion": "1",
  "mode": "html",
  "phases": {
    "scan": 123456,
    "render": 654321
  },
  "counters": {
    "page_reads": 4,
    "include_reads": 0,
    "hash_bytes": 39064,
    "link_resolutions": 7,
    "fast_path_hits": 0
  },
  "totalNs": 44142167
}
```

`phases` contains only phases that ran, in canonical order: `scan`, `parse`,
`graph_validate`, `dependency_resolve`, `fingerprint`, `render`,
`heading_harvest`, `search`, `link_audit`, `inventory`, `checks`, `claims`,
`touches`, `proof_pack`. IR, RAG, context, llms, and RSS modes stop at the
compiler-core phases; the HTML publication phases are recorded on the HTML
path. Durations and `totalNs` are integer nanoseconds from the monotonic
clock, so the shape and key order are deterministic even though wall times
vary between runs. `counters` always appears with every key in canonical
order: `page_reads`, `include_reads`, `hash_bytes`, `link_resolutions`,
`fast_path_hits`. The last counter includes route-audit references that take
the canonical, caller-scratch fast path, in addition to the existing
heading-harvest and incremental-cache fast paths.

## RSS mode

`--rss` and `--rss-path PATH` select the deterministic RSS-only projection.
It requires `--site-url`, `--rss-title`, and `--rss-description`; `--rss-limit`
is 1–500 (default 20). RSS is incompatible with every other build projection,
`validate`, `check`, and `impact`. See the normative
[RSS 2.0 contract](rss-2.0.md).

## Nostr NIP-23 publication

Three subcommands publish documentation pages as NIP-23 long-form-content
events. The secret and the network are never mixed: `nostr sign` is the only
command that reads a key (once, from stdin), and `nostr publish` is the only
command that contacts a relay. A bare `boris build` never needs a key, a
relay, or the network.

```text
boris nostr plan --profile PATH
boris nostr sign --plan PLAN.json --key-stdin [--out BUNDLE.json] [--prior PRIOR.json] [--created-at N]
boris nostr publish --plan PLAN.json --bundle BUNDLE.json [--out REPORT.json]
```

| Command | Key | Network | Writes by default |
|---------|-----|---------|-------------------|
| `nostr plan` | never | never | Plan JSON on stdout |
| `nostr sign` | once, from stdin | never | Bundle JSON on stdout or `--out PATH` |
| `nostr publish` | never | the plan's relays | Report JSON on stdout or `--out PATH` |

`nostr sign` options: `--plan PATH` (required), `--key-stdin` (required; the
key is 64 hex digits or a NIP-19 `nsec`, read once and zeroed best-effort —
never from argv, profile, environment, or diagnostics), `--out PATH` (bundle
output path; default stdout), `--prior PATH` (prior signed bundle for the
same `(kind, pubkey, d)` address, to reuse unchanged evidence and enforce
strict `created_at` update ordering), and `--created-at N` (explicit unix
seconds; test/recovery only). `nostr publish` options: `--plan PATH`
(required), `--bundle PATH` (required; verified against the plan before
anything is sent), and `--out PATH` (report output path; default stdout).

Exit codes: `0` success (`nostr sign` wrote a bundle; `nostr publish`
wrote a report — the publish verdict lives in the report, not the code,
even when relays emit `ENOSTRRELAY`); `1` content failure, including
`ENOSTRSIGN` refusals and `ENOSTRTIME` ordering violations (no bundle or
report is written); `2` usage error (missing `--plan`/`--key-stdin`/
`--bundle`, an invalid `--created-at`, relay configuration refused by the
strict profile parser, or a plan/bundle over the size bound); `3` I/O or
system failure. See the normative
[`nostr-publication` contract](nostr-publication.md) for the plan, signed
bundle, and report artifacts, the `created_at` update-ordering rules, and
the hostile mock-relay conformance matrix.

## HTML sitemap flags

`--sitemap` adds `sitemap.xml` to a single HTML target.
`--sitemap-path PATH` implies sitemap publication and selects another
target-root-relative file. Both require the reusable `--site-url` HTTP(S) base.
Sitemap flags are valid for `build` and `validate` on one selected HTML target.
They are invalid with non-HTML projections, `check`, `impact`, or an ambiguous
multi-target configuration. `--site-url` without RSS or sitemap selection is
also a usage error. Validation renders sitemap bytes in memory and discards
them; only `build` publishes the file. See the normative
[XML sitemap contract](xml-sitemap.md).

## Serialization profile (`--target-profile`)

`--target-profile NAME=PROFILE` selects Oliver's serializer profile for one
HTML target (`NAME` must match a `--target` or the synthetic `default`;
repeatable). `PROFILE` is `html` (default, byte-identical to pre-profile
output) or `xhtml` (XML-compatible serialization of the same normalized
document).

An XHTML *document* is a layout concern: the layout template emits the XML
declaration + `<html xmlns="http://www.w3.org/1999/xhtml">` and the page-body
slot receives the XHTML fragment. The profile fails closed — verbatim raw
HTML in content is a hard build error on an XHTML target
(`error.RawHtmlNotXmlWellFormed`, surfaced with page/offset context in the
diagnostics surface); the same bytes render fine under `html`. Flipping a
target to XHTML requires a raw-HTML sweep of its content first. See the
[multi-target contract](multi-target-isolated-output.md) and
[Oliver renderer contract](oliver-renderer.md).

`--target-profile` implies HTML mode, is valid for `build` and `validate`
(the no-publication HTML path renders with the selected profile in memory),
and is rejected by non-HTML projections, `check`, and `impact`.

## Hosted publication location flags

`--pages-base-url URL`, `--pages-origin URL`, and `--pages-base-path PATH`
select one normalized GitHub Pages identity for HTML, RSS, or `llms.txt`
output. All three are required together; `PATH` may be explicitly empty for a
root site or custom domain. The parser applies the same shape, origin, and
base-path checks as the publication profile. The flags are accepted by
`validate` for HTML preflight and rejected with IR, RAG, Context, `check`, and
`impact`, whose current artifacts have no applicable public URL field.

When selected, the identity is execution configuration, not a deployment claim.
Applicable generated URLs are checked locally and a mismatch fails the
publication with `EPUBLICATIONLOCATION`; no post-deploy HTTP request is made.

## Compatibility rule

Adding a flag or report field is additive only when it preserves existing
command routing, exit behavior, key order, and deterministic sorting. Changing
the meaning of a command, exit code, report field, or path policy requires an
amended contract and a versioned schema change.
