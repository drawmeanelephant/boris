# Takeout migration-lab intake contract

This is a bounded intake contract for future Facebook, Instagram, and Google
Takeout dogfooding. It defines how evidence enters the migration laboratory;
it does not claim that Boris has validated any provider's current export
format.

## Boundary

Takeout adapters are standalone tools under `tools/migration-lab/`. They may
read an unpacked local export and write a new report or draft content tree
under an explicit output directory. They must not become dependencies of the
product compiler, import product `src/` modules, fetch provider APIs, or
rewrite source files or media.

The provider-neutral intake shape is:

```text
local export bytes
  -> provider adapter (future, source-specific)
  -> sanitized fixture + intake manifest
  -> human review / expected output
  -> Boris-ready Markdown only after review
```

The synthetic fixture in
[`tools/migration-lab/fixtures/takeout-intake/`](../../tools/migration-lab/fixtures/takeout-intake/)
demonstrates a possible record vocabulary. It is deliberately not a copy of
Facebook, Instagram, or Google Takeout.

## Directory convention

```text
tools/migration-lab/fixtures/takeout-intake/
  raw-local/                  # real unpacked exports; ignored and never committed
  sanitized-fixture/          # committed, scrubbed, minimal source-shaped bytes
  expected-output/            # committed expectations, not generated site output
  review-notes/               # committed evidence and unresolved questions
```

`raw-local/` is ignored by the repository and must remain empty in commits.
Use a path outside the repository when an export is especially sensitive.
Generated Markdown, HTML, reports, and caches belong under an ignored
`test-output/` path or a temporary directory, not under `expected-output/`.

## Common fixture manifest

Every committed fixture has a JSON manifest with these fields:

| Field | Requirement |
|---|---|
| `schema` / `schema_version` | `boris-takeout-fixture` and an integer version |
| `fixture_id` | Stable, non-personal identifier |
| `source_family` | Provider family or `synthetic-social`; never guessed from filenames |
| `provider` | Provider name only when confirmed; `none` for synthetic fixtures |
| `export_version` / `export_date` | Exact source metadata when known; `synthetic-*` and a synthetic date otherwise |
| `privacy_scrub_status` | Explicit status, such as `verified-sanitized` or `synthetic-only-no-personal-data` |
| `files_included` | Sorted repository-relative paths and their role |
| `expected_pages` / `expected_assets` | Human-reviewed page and asset identities, not generated output claims |
| `known_omissions` | What the fixture intentionally does not represent |

Real fixtures also record the source revision or export fingerprint in review
notes. They must not record account ids, emails, GPS, private media, access
tokens, or unredacted URLs.

## Evidence checklist

An importer run is not evidence until the review notes record:

- exact input bytes or a cryptographic digest of each input file;
- source/provider revision and the adapter revision;
- exact command, working directory, and tool versions;
- output tree and exit status;
- repeated-run determinism result;
- duplicate post, album, link, and media handling;
- media existence, collision, and unsupported-type handling;
- timezone policy, including whether timestamps are normalized or preserved;
- provenance from output records back to sanitized source paths;
- privacy checks for names, emails, IDs, GPS, device data, private media, and URLs;
- omissions, warnings, and manual-review decisions.

An importer must fail closed or preserve an explicit review item when it cannot
establish a mapping. It must not invent provider semantics from a filename,
caption, or undocumented field.

## Initial unsupported claims

This contract does not promise:

- a Facebook or Instagram parser beyond the existing bounded Instagram lab;
- a Google Takeout parser of any kind;
- universal handling of albums, reactions, stories, comments, links, or timezones;
- preservation of provider privacy/audience semantics in Boris frontmatter;
- automatic identity resolution, deduplication, or media repair;
- import of raw exports into the product compiler.

Those are future adapter-specific cards that require real, consented, sanitized
samples and their own fixtures.
