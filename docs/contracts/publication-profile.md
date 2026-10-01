# Publication profile (schema v1, GitHub Pages declaration slice)

**Status:** normative parser, static-plan, and bounded HTML execution contract.
`boris plan --profile PATH` declares the full profile. With no HTML CLI
selectors, `build`, `watch`, and `validate --profile PATH` execute the declared
HTML configuration through the existing compiler coordinator; validation
stops at its zero-write prepublication boundary. Unsupported declarations
fail with exit 2 before any target is written. An HTML `build --profile PATH`
with explicit HTML selectors retains the matching Standard.site/Nostr metadata
opt-in described below. The internal
parser and plan command do not discover content, create outputs, read
environment variables, contact a network service, or invoke a publisher. See the
[publication-plan contract](publication-plan.md) for the declaration format.

## Selected profile workspace

A caller explicitly selects one profile file. Its path is normalized against
the invocation CWD and the normalized parent directory is the profile
workspace root. Every path in the profile, and every profile-mode CLI
path override, is workspace-relative. Absolute paths, drive-rooted paths,
backslashes, empty segments, `.` segments, and `..` segments are rejected.
There is no Git-root, package-root, parent-directory, or conventional-file-name
discovery. Legacy no-profile invocations retain their CWD-relative behavior.

The parsed plan stores only canonical workspace-relative paths. The HTML
coordinator resolves input/output/static roots and opens relative layout/theme
paths against the owned workspace root, without changing process CWD.

## Strict JSON and bounds

The profile is UTF-8 JSON with no embedded NUL. The Boris parser rejects
malformed JSON, comments, trailing data, coercion, duplicate keys, and unknown
keys at every object level. Duplicate rejection is a Boris parser requirement;
the companion JSON Schema cannot express it alone.

| Bound | Value |
|---|---:|
| Profile bytes | 262,144 |
| JSON nesting | 16 containers |
| Decoded string bytes | 4,096 |
| Path bytes | 1,024 |
| Targets | 32 |
| Any supported array | 256 |
| Layout rules per target | 256 |
| Target-name bytes | 64 |
| Site title/description bytes | 1,024 |

Crossing a bound fails before a plan is returned. `schema_version` is an exact
non-negative integer `1`; floats, negative values, and integer overflows do
not coerce to it.

## Schema v1

The root has exactly these fields:

| Field | Required | Meaning |
|---|---|---|
| `format` | yes | Exact string `boris-publication-profile` |
| `schema_version` | yes | Exact integer `1` |
| `input` | no | Content root, default `content` |
| `input_format` | no | `markdown` (default), `textile`, or `cook` |
| `site` | no | Closed `url`, `title`, `description` object |
| `publication` | no | Closed publication-target declaration; `github-pages` or `standard-site` |
| `targets` | no | Closed HTML-target array |
| `editions` | no | Closed `ir`, `rag`, `context` object |
| `nostr` | no | Closed Nostr publication-surface declaration; see [nostr-publication.md](nostr-publication.md) |

When present, `publication` requires exactly one `public` HTML target. Its
closed fields are:

| Field | Required | Meaning |
|---|---|---|
| `target` | yes | Closed registry: exact string `github-pages` or `standard-site` |
| `base_url` | yes | Normalized public URL, including the project-site path when applicable |
| `origin` | yes | Normalized scheme and authority with no path |
| `base_path` | yes | `/repo` for a project site, or the empty string for a root/custom-domain site |

A `target` of `standard-site` also accepts the Standard.site fields `did`,
`name`, `description`, `show_in_discover`, `include` / `exclude`, `prune`,
and optional `pds`. Those fields and their constraints live in
[`standard-site.md`](standard-site.md). They are not GitHub Pages fields
and do not change this schema version.

Boris normalizes trailing slashes, requires `base_url == origin + base_path`,
and rejects origin/path contradictions. A `github.io` origin with a non-empty
path is classified as a project site; a pathless `github.io` origin is a root
site; any other pathless valid origin is classified as a custom domain. Custom
domains with a non-empty base path are rejected because this declaration does
not guess at CNAME or host configuration. If `site.url` is supplied, it must
equal the normalized publication `base_url`; this prevents sitemap/RSS and
Pages metadata from silently naming different locations.

Each target requires `name` and `output`; optional fields are `public`, exactly
one of `theme`/`layout`, `layout_rules`, `sitemap`, `rss`, `llms`, and
`static`.
`layout_rules` entries contain exactly `selector` and `layout` and use the
existing closed selector grammar and canonical ordering. A target's `sitemap`,
`rss`, `llms`, and `static` objects respectively allow only `path`,
`path`/`limit`, `path`, and `dir`. `static.dir` (#804) is a project-relative
input directory whose contents copy byte-identically into the target root; it
may not nest with the target output or the content root in either direction.
Project editions require `output`; RAG also accepts `scope`,
`split_size`, and `bundles_only`, while Context accepts `scope` and
`split_size`.

URL validation is the existing bounded RSS/sitemap HTTP(S) grammar. Sitemap,
RSS, and llms paths are target-relative and use the existing compiler-owned
namespace protections. At least one HTML target or machine edition is required.

## Normalization, ownership, and overrides

`PublicationPlan` is owned immutable-semantic publication intent: input,
format, metadata, canonical targets/rules, selected editions, and the
optionally declared Nostr surface. It owns every
string and rule slice; no raw JSON node, JSON key slice, or argv view crosses
the parser boundary. `PublicationExecution` separately contains `jobs`,
`incremental`, and `quiet`; those controls are deliberately absent from plan
identity.

Targets sort by name; layout rules sort by existing selector canonical order.
Object-key order has no semantic effect. `ProfileOverrides` retains omitted
versus explicit state. Precedence is compiled profile defaults, then selected
profile values, then explicit profile-mode overrides; static validation runs
again after overrides. A global HTML output override is rejected when a profile
contains multiple targets. A GitHub Pages declaration remains configuration;
it is not evidence that a deployment occurred.

## Static validation and the runtime boundary

Before discovery, Slice 1 validates discriminator/version, types and bounds,
site requirements, unique target names, at most one public target, public
artifact placement, theme/layout exclusivity, selector rules, lexical path
containment, target/edition/input/layout/theme overlaps, machine-root
separation, target-local public-artifact collisions, and known compiler-owned
roots (`.boris-cache`, `_boris/search`).

The parser does not perform dynamic ownership validation. Executed HTML targets
use the existing compiler checks over discovered content, layouts, assets,
routes, and staged output inventory for page/asset/derived-route collisions,
filesystem conflicts, and symlink safety. Existing per-target staging and
per-file commit limitations remain unchanged; profile execution adds no
whole-publication transaction. URL projection audits, deployment verification,
and post-deploy HTTP checks remain outside the profile parser and plan
declaration. Runtime HTML/RSS/llms coordinators may consume the normalized
profile identity as one shared `{base_url, origin, base_path, site_kind}`
value; any applicable local URL disagreement is then a publication failure,
while artifacts with no public URL field remain explicitly not applicable.

## Offline and availability boundary

Profile parsing is local, deterministic, and offline. URLs are strings to
validate, never endpoints to probe. There are no includes, aliases,
expressions, environment substitution, network access, plugins, deployment
settings, secrets, watch configuration, source-RAG, migration labs, or generic
tasks in schema v1. The one exception is the closed `nostr` section: it
declares relay endpoints, `timeout_ms`, and `retries` as reviewable transport
declarations ([nostr-publication.md](nostr-publication.md)) — parsing never
probes a relay, and only `nostr publish` reads those controls for behavior.
The additive schema-1 profile grammar also accepts a closed optional
`nostr.auth` object with exactly `mode: "nip42"` and a non-empty normalized
`relays` subset of the enabled Nostr relay list. URLs are bounded to 1,024
UTF-8 bytes. Unknown/duplicate keys, disabled Nostr, unknown modes, wrong
types and non-subsets fail preflight. The implementation's existing relay
limit is **32**, not the 256 incorrectly described in the phase-1 handoff.
This does not broaden the relay limit. A profile with authentication emits
schema-2 plans so a schema-1 consumer cannot silently omit the requirement;
old strict profile parsers reject the added `auth` key.
The plan CLI is intentionally a declaration surface rather
than a publication coordinator. Full profile execution remains deferred until
a coordinator can execute every configured entry without silently ignoring any
of them.

### HTML execution

```text
boris build --profile boris.json
boris watch --profile boris.json --serve
boris validate --profile boris.json --report diagnostics.json
```

Without explicit HTML selectors, the profile selects input, input format,
target names/outputs, fallback theme/layout, layout rules, static files,
sitemap, and publication location. All declared HTML targets execute in
canonical name order with the existing target-isolation, staging, cache, and
failure policies. No synthetic `default` target replaces a declared target.
Standard.site verification and enabled Nostr head links remain offline,
opt-in metadata surfaces, not network publication.

Explicit `--input` and `--textile`/`--cooklang` override profile input values
and are validated again; paths remain workspace-relative. `--quiet`, `--jobs`,
`--incremental`, and `--refresh-evidence` retain their normal build meanings.
Validation still rejects build execution controls and competing HTML selectors.
`--report` retains its normal CWD-relative explicit-file meaning.

This slice refuses profile editions (`ir`, `rag`, `context`), target RSS/llms,
multi-target sitemap/static or publication metadata, and sitemap without
`site.url`. Watch also refuses Standard.site verification (its projection
cannot yet be refreshed each cycle); Standard.site verification refuses input
overrides. Each refusal names the unsupported field and exits 2 even under
`--quiet`, before writing a subset. These are execution boundaries, not
changes to what the profile parser or `plan` accepts.

Watch uses a startup snapshot of the profile. Restart after changing the
profile itself. Content, layouts, theme assets/footer, and the selected static
directory participate in the normal watch feedback loop; Nostr links persist
across rebuilds. `--serve` serves the first canonical target, and SIGINT/SIGTERM
retain the normal exit-0 shutdown. Watch with competing HTML selectors is a
usage error. `validate --profile --watch` remains unavailable.

### Existing explicit-selector metadata opt-in

For HTML `build --profile` with explicit HTML selectors, Boris requires one
declared target and one selected CLI target, then compares the profile's
workspace-relative `input`, `input_format`, target name/output, fallback
theme/layout, layout rules, static directory, and sitemap path/URL against
the effective CLI configuration. An explicitly selected Pages location must
agree with the profile's publication URL. It also refuses profile editions
(IR/RAG/Context), target RSS/llms declarations, and profiles with no enabled
Standard.site or Nostr metadata surface. A mismatch is an exit-2 error naming
the first unselected field/target before output is written, even with
`--quiet`; matching CLI flags continue to emit Standard.site and Nostr
surfaces. To use the profile as the source of HTML configuration instead,
omit those explicit HTML selectors.
