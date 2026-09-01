# Publication plan (schema v1)

**Status:** normative first declaration slice. `boris plan --profile PATH`
reads one explicitly selected local publication profile, normalizes it through
the owned `PublicationPlan`, validates that plan with the existing profile
validator, and writes one canonical JSON declaration to stdout. It does not
compile or publish any projection.

## CLI

```text
boris plan --profile PATH
```

`PATH` is required and is the only profile-selection mechanism. The selected
profile is read relative to the invocation CWD when it is relative; its
workspace is the normalized parent of the selected profile path, as defined by
the [publication-profile contract](publication-profile.html). The profile path
and absolute workspace are never fields in the declaration.

The existing profile-mode publication overrides are available on this command:

- `--input PATH` overrides the normalized content input.
- `--textile` and `--cooklang` each override the normalized input format;
  they are mutually exclusive, and supplying both is a usage conflict.
- `--html-dir PATH` overrides the HTML output when the profile has exactly one
  HTML target.

The existing execution controls `--jobs`, `--incremental`, and `--quiet` may be
accepted for grammar compatibility, but they remain `PublicationExecution`
state and are never plan identity. Other output selectors and commands are
usage conflicts. `--out` keeps its existing IR meaning and is not an alias for
the plan declaration.

The command emits JSON only after profile reading, normalization, override
application, validation, and complete rendering succeed. Invalid profile
syntax, unknown or duplicate keys, invalid paths, target conflicts, missing
public-artifact metadata, and invalid overrides produce exit code `2` and no
declaration on stdout. Profile read failures, allocation failures, and stdout
I/O failures use the established exit code `3` path. This slice has no plan-file
output flag, so it cannot replace a prior plan artifact.

## Canonical artifact

The JSON format is `boris-publication-plan`, schema version `1`. The published
machine-readable schema is
[`publication-plan-1.schema.json`](https://github.com/drawmeanelephant/oliver/blob/main/docs/contracts/schemas/publication-plan-1.schema.json).
All root, target, projection, and edition keys are emitted in the fixed order
shown below; object-key order in the source profile has no effect.

```json
{
  "format": "boris-publication-plan",
  "schema_version": 1,
  "input": "content",
  "input_format": "markdown",
  "site": null,
  "targets": [],
  "editions": {
    "ir": null,
    "rag": null,
    "context": null
  }
}
```

`input_format` renders as `markdown`, `textile`, or `cook`.

Optional normalized values use explicit `null` so consumers can compare a
complete plan shape without guessing whether a field was omitted. The optional
`publication` object is emitted between `site` and `targets` when the selected
profile declares a GitHub Pages target:

```json
"publication": {
  "target": "github-pages",
  "base_url": "https://owner.github.io/boris",
  "origin": "https://owner.github.io",
  "base_path": "/boris",
  "site_kind": "project-site"
}
```

The location is normalized and cross-checked by the profile parser; it is not
a deployment result. A target is
an HTML target (`projections.html` is always `true`) and carries normalized
`name`, `output`, `public`, `theme`, `layout`, and ordered `layout_rules`.
Configured sitemap, RSS, and `llms.txt` projections appear under
`projections`; absent projections are `null`. RSS `limit` and RAG
`bundles_only` contain the defaults established during profile normalization.
The current profile model has no search projection field, so this artifact does
not invent one.

The `editions` object reports the selected IR, RAG, and Context configurations.
It does not execute them and does not report their emitted files.

## Normalization and determinism

The renderer accepts a borrowed `PublicationPlan`, never raw `std.json` values
or argv slices. Profile parsing owns strings and rules, applies the existing
override precedence, sorts targets by canonical name, and keeps the established
semantic layout-rule order. The renderer does not re-sort or infer fields.

The bytes are deterministic for equivalent normalized plans: fixed UTF-8 JSON,
LF line endings, fixed object-key order, canonical target/rule order, and
escaping through Boris's shared `json_out` helper. No timestamps, host data,
usernames, process IDs, environment values, absolute paths, temporary names,
Git revisions, or publication-success claims are emitted.

The declaration contains publication identity and selected projection
configuration only. It excludes `jobs`, `quiet`, `incremental`, temporary
staging names, and runtime worker decisions. It also excludes content scan
results, graph compilation, artifact inventories, file digests, checks, claims,
limitations, touch maps, quality scores, deployment status, environment URLs,
HTTP responses, and any claim that a Pages artifact was accepted or served.

The normalized publication identity is also the runtime source of truth for
location-aware HTML, sitemap, RSS, and `llms.txt` producers when a coordinator
executes the plan. This declaration itself does not run those producers or
their local URL gates; it is not deployment verification. IR, RAG, Context,
and rendered-search v1 currently have no applicable public URL field.

## Side-effect and future-evidence boundary

`plan` performs no content scan, graph compilation, HTML render, IR/RAG/Context
export, sitemap/RSS/search/llms publication, network access, source mutation,
target-directory creation, or cache creation. A successful output means only
that Boris has a declared and statically validated normalized plan.

This declaration is not proof, evidence, verification, or a success report.
Future publication-evidence or proof-pack artifacts may refer to a plan as the
declared configuration they assessed, but they must separately describe what
was emitted, which checks passed, what claims were verified, and what touched
the output. Those later artifacts must not be silently folded into this schema.
