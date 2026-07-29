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

The stream covers directories and hidden entries as well as files. Symlinks are never followed. The committed schemas describe the full record and action shapes; they are parsing contracts, not a claim that a Draft 2020-12 validator is run by this tool or CI.

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
separate Markdown-link/image and reference-class inventories, and
classification evidence. Normal links are not assets. Proposed actions are
only `create`, `keep`, `quarantine`, `unsupported`, `review`, or `conflict`.
No update/move/delete/apply action exists in v1.

Duplicate authored IDs, import-record IDs, normalized source paths, proposed Boris entity/source paths, or inferred routes are conflict evidence; the plan does not choose a winner. Previous manifests are accepted only when they have the exact v1 object shape, matching project/policy digests, well-formed record IDs, and unique normalized paths and IDs. They preserve ownership solely for one exact same-path record.
