# Astro import plan (v1)

**Status:** normative developer-tool contract — plan-only vertical slice.

`boris-migration-lab --mode=astro-import-plan` is a read-only source analysis
and plan generator. It is separate from `--mode=astro`; the latter keeps its
existing archaeology report contract unchanged.

## Supported profile and boundary

The only candidates for `create` are explicit lowercase `.md` files below the
user-supplied relative `--content-root`, with ordinary Markdown bodies and only
bounded `id`, `title`, `status`, and `tags` frontmatter. `id`, `title`, and
`status` use the Boris scalar grammar; `tags` uses the exact bounded bracket-list
grammar. The tool never runs
Astro, Node, MDX, ESM, integrations, or project JavaScript; fetches nothing;
modifies no input; emits no Markdown; applies no action; copies no asset; and
does not infer parents/navigation or call an inferred route observed.

`.mdx`, `.astro`, symlinks, executable/framework syntax, nested YAML, and
unknown metadata are explicit `quarantine` or `unsupported` plan rows. They
are not converted and unknown metadata is never appended to body prose.

The selected content root is opened one component at a time without following
symlinks. A symlink at the selected path or in any component between `--root`
and that path is rejected before scanning or staging, including a symlink whose
target remains beneath `--root`. Internal symlinks discovered after the scan
begins are inventoried without traversal.

The executable-syntax classifier is conservative and code-aware. Backtick and
tilde fences (including marker lengths greater than three), variable-length
backtick code spans, escaped punctuation, and indented code lines are literal
Markdown and do not trigger MDX classification. Outside those boundaries, ESM
imports/exports, JSX components/fragments, MDX braces, Astro directives, and
ambiguous executable-looking syntax cannot receive `create`.

The supported frontmatter grammar follows
[`frontmatter.md`](frontmatter.md): blank/whitespace-only lines are skipped;
inline `#` text is ordinary scalar content rather than comment syntax; a
standalone comment-looking line is malformed because it has no `:`. Duplicate
keys, single quotes, malformed double quotes, invalid status/tags, nested or
multiline forms, empty values, and unknown keys are rejected. Accepted `id`,
`title`, `status`, and `tags` are all retained in
`proposed_closed_frontmatter` with their correct JSON types.

## Complete source evidence and scan failures

The snapshot inventories **every** entry below the selected root, including hidden names, directories, ordinary unsupported files, and symlinks. A regular file retains its exact byte SHA-256 even when it is unsupported. `.mdx` and `.astro` have `frontmatter_hash` and `body_hash` set to JSON `null`, meaning “not parsed”; a symlink has all hashes `null` and an un-followed `symlink_target`. Empty strings are never hash values.

The scan is fail-closed: iterator, stat, read, link-read, or unsupported filesystem-object failures abort the command before staged publication. No successful partial snapshot is published.

`source_tree_fingerprint` hashes this exact canonical UTF-8 stream, sorted by normalized relative source path:

```text
boris-astro-source-tree-v1\n
path:<decimal byte length>:<raw path>\n
kind:<decimal byte length>:<raw kind>\n
sha256:<64 lowercase hex or null>\n
symlink_target:<decimal byte length>:<raw target>|null\n
```

The stream covers directories and hidden entries as well as files. Symlinks are
never followed. The committed schemas describe the full record and action
shapes. The migration-lab `schema-test` lane runs them through the test-only Ajv
Draft 2020-12 implementation against exact valid runtime payloads and committed
malformed mutation cases. Boris does not load a schema engine at runtime.

## Invocation and publication

All of `--root`, `--content-root`, `--out`, and `--project-id` are required for
this mode. `--content-root` is a normalized, non-escaping path relative to the
root. The output must not overlap source inputs. Artifacts are fully written to
the migration lab's owned sibling stage, then committed as one owned output:

```text
source_snapshot.json
import_plan.json
REPORT.md
```

No successful-import manifest is produced in this slice.

## Identity

Source-authored identity (`id` when actually present), importer-assigned
import-record identity, current source path, inferred route candidate, and
rename evidence are separate fields. Initial import-record IDs are:

```text
"air_" + sha256("boris-astro-import-record-v1\\n" + project_id + "\\n" + source_path)
```

where the hash is exactly 64 lowercase hexadecimal characters. Routes and
slugs are not durable identities. An optional previous completed-apply manifest
must use `boris-astro-import-manifest` schema 1 and match both project and
policy digests; it can preserve a same-source-path record ID only. Hash matches
are review evidence, never automatic rename/move evidence.

## Canonical JSON and digests

The committed [policy artifact](astro-import-plan-policy-v1.json) is compact
UTF-8 JSON and its SHA-256 is `policy_hash`. All emitted JSON is compact UTF-8,
uses the fixed key order emitted by the tool, and arrays are sorted by source
path. No timestamps, host paths, locale output, random IDs, or hash-map order
are allowed.

`source_snapshot_digest` is SHA-256 of `source_snapshot.json` bytes.
`plan_digest` is SHA-256 of the exact compact object stored as
`import_plan.json.digest_input`; the outer `plan_digest` and `digest_input`
wrapper is excluded. Every digest is lowercase SHA-256 hexadecimal.

The snapshot records exact source, frontmatter, and body hashes, source kind,
authored identity evidence, an explicitly `inferred_not_observed` route,
typed `references` and `potential_asset_references`, and classification
evidence. Reference syntax distinguishes inline links, inline images,
reference-style link/image uses, reference definitions, and angle-bracket
autolinks. Target classification distinguishes fragments, root-relative,
source-relative, protocol-relative, HTTP, HTTPS, `mailto:`, `ftp:`, other
explicit schemes, data URLs, reference labels, and malformed/review evidence.
Exact duplicate typed references are deterministically deduplicated. Literal
code examples are excluded. Normal links are never assets; image evidence is
only a potential asset reference and makes no existence, resolution, copying,
route, or publication claim. Proposed actions are
only `create`, `keep`, `quarantine`, `unsupported`, `review`, or `conflict`.
No update/move/delete/apply action exists in v1.

Planning is phased: scan/parse, generate importer IDs, restore valid same-path
manifest IDs, derive entity/source/route proposals, validate every proposal,
then perform one collision pass over the exact final values before assigning
actions. A `create` or `keep` requires a valid exact source hash, importer ID,
nonempty Boris entity, nonescaping proposed source path, nonempty inferred
route, proposed route, and nonempty preconditions. Invalid proposals use null,
never empty strings.

Duplicate authored IDs, generated or final import-record IDs, normalized source
paths, proposed Boris entity/source paths, inferred routes, or proposed routes
are conflict evidence; the plan does not choose a winner. Findings retain every
involved normalized source path in deterministic order. Previous manifests are
accepted only when they have the exact v1 object shape, matching project/policy
digests, well-formed record IDs, and unique normalized paths and IDs. They
preserve ownership solely for one exact same-path record.

JSON Schema cannot prove cross-record uniqueness, same-path ownership, digest
equality, or collision grouping. Those checks remain runtime responsibilities;
the independent validation lane recomputes policy, source-tree, snapshot, and
plan digests in addition to schema validation.
