# Publication profile (schema v1, GitHub Pages declaration slice)

**Status:** normative parser and static-plan contract. Boris accepts an
explicit profile only through the stdout-only `boris plan --profile PATH`
declaration command; profile execution is not available in this slice. The
internal API and plan command parse and validate a selected local profile only;
they do not discover content, create outputs, read environment variables,
contact a network service, or invoke a publisher. See the
[publication-plan contract](publication-plan.html) for the declaration format.

## Selected profile workspace

A caller explicitly selects one profile file. Its path is normalized against
the invocation CWD and the normalized parent directory is the profile
workspace root. Every path in the profile, and every future profile-mode CLI
path override, is workspace-relative. Absolute paths, drive-rooted paths,
backslashes, empty segments, `.` segments, and `..` segments are rejected.
There is no Git-root, package-root, parent-directory, or conventional-file-name
discovery. Legacy no-profile invocations retain their CWD-relative behavior.

The parsed plan stores only canonical workspace-relative paths; the owned
workspace root carries the absolute path used by a future coordinator.

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
| `publication` | no | Closed publication-target declaration; currently `github-pages` only |
| `targets` | no | Closed HTML-target array |
| `editions` | no | Closed `ir`, `rag`, `context` object |

When present, `publication` requires exactly one `public` HTML target. Its
closed fields are:

| Field | Required | Meaning |
|---|---|---|
| `target` | yes | Exact string `github-pages` |
| `base_url` | yes | Normalized public URL, including the project-site path when applicable |
| `origin` | yes | Normalized scheme and authority with no path |
| `base_path` | yes | `/repo` for a project site, or the empty string for a root/custom-domain site |

Boris normalizes trailing slashes, requires `base_url == origin + base_path`,
and rejects origin/path contradictions. A `github.io` origin with a non-empty
path is classified as a project site; a pathless `github.io` origin is a root
site; any other pathless valid origin is classified as a custom domain. Custom
domains with a non-empty base path are rejected because this declaration does
not guess at CNAME or host configuration. If `site.url` is supplied, it must
equal the normalized publication `base_url`; this prevents sitemap/RSS and
Pages metadata from silently naming different locations.

Each target requires `name` and `output`; optional fields are `public`, exactly
one of `theme`/`layout`, `layout_rules`, `sitemap`, `rss`, and `llms`.
`layout_rules` entries contain exactly `selector` and `layout` and use the
existing closed selector grammar and canonical ordering. A target's `sitemap`,
`rss`, and `llms` objects respectively allow only `path`, `path`/`limit`, and
`path`. Project editions require `output`; RAG also accepts `scope`,
`split_size`, and `bundles_only`, while Context accepts `scope` and
`split_size`.

URL validation is the existing bounded RSS/sitemap HTTP(S) grammar. Sitemap,
RSS, and llms paths are target-relative and use the existing compiler-owned
namespace protections. At least one HTML target or machine edition is required.

## Normalization, ownership, and overrides

`PublicationPlan` is owned immutable-semantic publication intent: input,
format, metadata, canonical targets/rules, and selected editions. It owns every
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

## Static validation and the deferred boundary

Before discovery, Slice 1 validates discriminator/version, types and bounds,
site requirements, unique target names, at most one public target, public
artifact placement, theme/layout exclusivity, selector rules, lexical path
containment, target/edition/input/layout/theme overlaps, machine-root
separation, target-local public-artifact collisions, and known compiler-owned
roots (`.boris-cache`, `_boris/search`).

Dynamic ownership validation is deliberately deferred: it requires the
discovered content, layouts, assets, routes, and staged output inventory to
detect page/asset/derived-route collisions, actual filesystem conflicts, and
symlink races. This slice performs no publication, so it cannot claim those
checks or commit semantics. URL projection audits, deployment verification,
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
tasks in schema v1. The plan CLI is intentionally a declaration surface rather
than a publication coordinator. Full profile execution remains deferred until
a coordinator can execute every configured entry without silently ignoring any
of them.
