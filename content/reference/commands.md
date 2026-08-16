---
title: Command Reference
parent: reference
status: published
tags: [reference, cli, commands]
---

<p class="eyebrow">CLI</p>

# Command Reference {#command-reference}

<Aside kind="note">

This page is lookup. For which command to run first, see
[[guides/cli-and-modes|CLI & Output Modes]] and
[[guides/publishing|Publishing Targets]].

</Aside>

The public CLI has six core commands plus the `standard-site` family. With no
command, Boris runs `build` and publishes an HTML site under `dist/` — the
default target, not the only one.

## Commands at a glance

| Command | Purpose | Writes by default? |
|---|---|---:|
| `build` | Compile HTML or one selected machine/publication projection | Yes, to the selected output |
| `validate` | Run the HTML compiler preflight without publishing | No |
| `watch` | Build HTML, then watch for changes and rebuild | Yes |
| `check` | Report graph and dependency health after validation | No |
| `impact ID` | Report transitive dependents of a page or source endpoint | No |
| `plan --profile PATH` | Normalize a publication profile without publishing | No |
| `standard-site …` | Atmosphere plan / records / login / publish / smoke / logout | Depends on the subcommand |

## Basic usage

```bash
./zig-out/bin/boris build --input content --html-dir dist
./zig-out/bin/boris                         # same default HTML build
./zig-out/bin/boris validate --input content --quiet
./zig-out/bin/boris watch --input content --html-dir dist
```

`validate` is the authoritative no-publication HTML preflight. It checks the
same content, graph, renderer, layout, theme, target, and sitemap
configuration used by an HTML build, but writes no HTML, cache, search, IR,
RAG, Context,
`llms.txt`, RSS, sitemap, or publication-evidence files.

`check` is different: it runs Documentation Intelligence over a valid frozen
graph. It can return exit `1` for a policy finding such as an unreferenced
page, even when an HTML build is valid. Use `impact ID` to inspect transitive
dependents. Neither command checks layout/theme rendering or external URLs.

## HTML build and validation options

```bash
./zig-out/bin/boris build \
  --input content \
  --html-layout themes/boris/layouts/main.html \
  --html-dir dist

./zig-out/bin/boris validate \
  --input content \
  --html-layout themes/boris/layouts/main.html \
  --html-dir .tmp/validate
```

| Flag | Default | Description |
|---|---|---|
| `--input DIR` | `content` | Content root |
| `--html-dir DIR` | `dist` | Single HTML target output |
| `--html-layout PATH` | Product default theme layout | HTML layout file |
| `--theme ROOT` | — | Shorthand for `ROOT/layouts/main.html` plus its theme assets |
| `--target NAME=DIR` | — | Add a named HTML target; repeatable |
| `--target-layout NAME=PATH` | — | Layout fallback for a named target |
| `--layout-rule TARGET SELECTOR PATH` | — | Select layouts by `id:`, `role:`, or `glob:` |
| `--incremental` | off | Reuse the HTML cache where safe |
| `--watch` | off | Build and watch; equivalent to watch-compatible build behavior |
| `--jobs N`, `-j N` | `1` | Bound page-render workers; maximum `64` |
| `--textile` | off | Discover `.textile` input in addition to the normal Markdown path |

`--target` is mutually exclusive with `--html-dir`. A layout must contain
exactly one `{{content}}` marker; other markers are optional. See
[[guides/themes-and-layouts|Themes & Layouts]] for the layout vocabulary.

## Machine and publication projections

These are build projections. Select one projection per invocation and use
explicit paths in scripts so generated trees are easy to identify.

### JSON IR

```bash
./zig-out/bin/boris build --out .boris
```

Writes `manifest.json`, `graph.json`, and `build-report.json` under the chosen
directory. `--no-rag` is the explicit IR-only spelling when no `--out` path is
needed.

### RAG corpus

```bash
./zig-out/bin/boris build --rag --rag-dir rag
./zig-out/bin/boris build --rag --rag-dir rag --scope guides --split-size 2000000
```

`--scope` selects a bounded entity-id scope after validating the complete
graph. `--bundles-only` omits per-page files and emits only bundled parts.

### Context bundle

```bash
./zig-out/bin/boris build --context --context-dir context
```

The bundle contains Markdown, a manifest, a graph snapshot, and optional split
parts. A scoped bundle still validates the full graph first.

### `llms.txt`

```bash
./zig-out/bin/boris build --llms --llms-path public/llms.txt
```

The generated page links use Boris's current HTML routes, such as
`/guides/building-pages.html`; the file is a discovery projection, not a
second content model.

### RSS 2.0

```bash
./zig-out/bin/boris build --rss \
  --site-url https://docs.example/ \
  --rss-title "Example Docs" \
  --rss-description "Recent documentation updates" \
  --rss-path public/rss.xml \
  --rss-limit 20
```

RSS requires `--site-url`, `--rss-title`, and `--rss-description`. It includes
eligible pages with valid `published_at` and `summary` metadata. RSS is its own
projection and cannot be combined with HTML, IR, RAG, Context, `llms.txt`,
`validate`, `check`, or `impact`.

### XML sitemap

```bash
./zig-out/bin/boris build --sitemap --site-url https://docs.example/
./zig-out/bin/boris build --sitemap-path meta/sitemap.xml --site-url https://docs.example/
```

Sitemap publication is HTML-only, requires an HTTP(S) `--site-url`, and is
limited to one HTML target. The path is relative to that target. `validate`
accepts the same sitemap configuration but renders it in memory and discards
the result.

## Analysis output

```bash
./zig-out/bin/boris check --input content --format json --report .tmp/health.json
./zig-out/bin/boris impact guides/overview --input content --format human
```

| Option | Meaning |
|---|---|
| `--format human\|json` | Human summary or deterministic JSON; analysis commands only |
| `--report PATH` | Write the analysis report to PATH instead of standard output |
| `--quiet` | Suppress normal progress and diagnostic text where supported |

## Publication profiles

```bash
./zig-out/bin/boris plan --profile profiles/site.json
```

`plan` requires a profile and emits only the normalized publication declaration
to standard output. It does not discover content, validate a graph, or publish
an output. `--input`, `--textile`, and `--html-dir` can provide the supported
profile overrides; execution and projection flags are rejected.

## Standard.site family

```bash
./zig-out/bin/boris standard-site
./zig-out/bin/boris standard-site plan --profile profiles/standard-site.json
./zig-out/bin/boris standard-site records --profile profiles/standard-site.json
./zig-out/bin/boris standard-site login --app-password --handle YOU.test.bsky.social
./zig-out/bin/boris standard-site publish --profile profiles/standard-site.json --did did:plc:…
./zig-out/bin/boris standard-site logout --did did:plc:…
```

Offline `plan` / `records` / `verify` need no credentials. Live publish
against bsky.social uses `login --app-password`, not browser OAuth. App
passwords grant broad account write — use a dedicated test identity. See
[[guides/publishing#standard-site|Publishing Targets]].

GitHub Pages is not a `boris pages` verb. It is the official Actions
workflow plus `plan --profile` for the normalized location.

## Exit codes {#exit-codes}

| Code | Meaning |
|---:|---|
| `0` | Command completed successfully |
| `1` | Content/graph error, or a failing `check` health finding |
| `2` | Usage error, missing value, or conflicting flags |
| `3` | I/O or other system failure |

Common `1` diagnostics include `EFRONTMATTER`, `EPARENTMISSING`,
`EPARENTCYCLE`, `EREFERENCEMISSING`, include failures, and component failures.
For a compiler preflight, start with `boris validate`; use `check` only when
you want its separate health policy and report.

## Common options

| Flag | Description |
|---|---|
| `--help`, `-h` | Print the CLI help |
| `--quiet` | Reduce normal output |
| `--input DIR` | Select the content root |
| `--textile` | Enable explicit `.textile` discovery |

For the exact installed surface, run:

```bash
./zig-out/bin/boris --help
```

## Related pages

- [[guides/cli-and-modes|CLI & Modes]] — task-oriented command choices
- [[reference/frontmatter|Frontmatter Reference]] — accepted author metadata
- [[reference/outputs|Outputs & Artifacts]] — generated trees and schemas
- [[reference/diagnostics|Diagnostics & Troubleshooting]] — error triage
