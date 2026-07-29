# Astro import plan (v1)

**Status:** normative developer-tool contract — plan-only vertical slice.

`boris-migration-lab --mode=astro-import-plan` is a read-only source analysis
and plan generator. It is separate from `--mode=astro`; the latter keeps its
existing archaeology report contract unchanged.

## Supported profile and boundary

The only candidates for `create` are explicit lowercase `.md` files below the
user-supplied relative `--content-root`, with ordinary Markdown bodies and only
scalar `id`, `title`, `status`, and `tags` frontmatter. The tool never runs
Astro, Node, MDX, ESM, integrations, or project JavaScript; fetches nothing;
modifies no input; emits no Markdown; applies no action; copies no asset; and
does not infer parents/navigation or call an inferred route observed.

`.mdx`, `.astro`, symlinks, executable/framework syntax, nested YAML, and
unknown metadata are explicit `quarantine` or `unsupported` plan rows. They
are not converted and unknown metadata is never appended to body prose.

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
asset-reference inventory, and classification evidence. Proposed actions are
only `create`, `keep`, `quarantine`, `unsupported`, `review`, or `conflict`.
No update/move/delete/apply action exists in v1.
