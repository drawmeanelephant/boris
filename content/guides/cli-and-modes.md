---
title: CLI & Output Modes
parent: getting-started
status: published
tags: [cli, guides]
---

<p class="eyebrow">Commands</p>

# CLI & Output Modes {#cli-and-modes}

Boris has one native CLI with explicit command and projection boundaries. Use
this page to choose a command; use the [[reference/commands|Command Reference]]
for every flag and conflict rule.

<Aside kind="info">

Bare `boris` and `boris build` both publish the default HTML target under
`dist/`. `boris validate` is the no-publication compiler preflight. `boris
check` is graph-health analysis, not an alias for validation.

</Aside>

## Commands at a glance

| Command | Answers | Writes by default |
|---|---|---|
| `boris build` (or bare `boris`) | Can Boris publish the selected output? | HTML target and its selected publication artifacts |
| `boris validate` | Would the selected HTML source/configuration survive prepublication compilation? | Nothing |
| `boris watch` | Build HTML, then rebuild after debounced changes | HTML target and cache |
| `boris check` | What graph/dependency health facts and policy findings exist? | Nothing, unless `--report` is supplied |
| `boris impact ID` | Which pages or source endpoints depend on this id? | Nothing, unless `--report` is supplied |
| `boris plan --profile PATH` | What normalized publication declaration does this profile describe? | JSON declaration on stdout |
| `boris standard-site …` | Atmosphere plan / records / login / publish / smoke | Depends on the subcommand |

> Pick the command that matches the question. `validate` is not `check`.
> `plan` does not publish. `standard-site` is a family, not the default path.

`watch` is HTML-only. The compatibility flag `--watch` and `build --watch`
remain accepted. `check` and `impact` operate only after the graph is valid;
their first policy slice can return exit `1` for findings such as an
unreferenced page.

## The normal HTML path

```bash
./zig-out/bin/boris build --quiet
./zig-out/bin/boris validate --quiet
./zig-out/bin/boris --html-dir public --quiet
./zig-out/bin/boris watch --html-dir public --quiet
```

The default managed layout is
`themes/boris/layouts/main.html`. Use `--html-layout PATH` for one layout or
`--theme ROOT` for a theme root containing `layouts/main.html` and managed
assets. `--incremental` reuses content-addressed HTML work; `--jobs N` bounds
parallel HTML page workers from 1 through 64.

## Machine projections

Each projection is a separate invocation over the same content tree:

```bash
./zig-out/bin/boris --out .boris --quiet       # JSON IR
./zig-out/bin/boris --rag --quiet              # RAG corpus under rag/
./zig-out/bin/boris --context --quiet          # Context Bundle under context/
./zig-out/bin/boris --llms --quiet             # llms.txt
```

RAG and Context support `--scope`, `--split-size`, and the RAG-only
`--bundles-only` option. `--out` selects IR; it is not a request to add IR to a
normal HTML build.

## RSS and sitemap

RSS is a standalone projection and requires its public metadata:

```bash
./zig-out/bin/boris --rss \
  --site-url https://docs.example/ \
  --rss-title "Example Docs" \
  --rss-description "Recent updates" \
  --quiet
```

An HTML sitemap is selected on the HTML path and uses the same deployment base:

```bash
./zig-out/bin/boris --sitemap \
  --site-url https://docs.example/ \
  --quiet
```

RSS and sitemap are different projections. RSS flags cannot be combined with
HTML, IR, RAG, Context, `llms.txt`, `check`, or `impact`; sitemap is an HTML
target option and requires exactly one unambiguous target.

## Multiple HTML targets and layouts

Use repeatable `--target NAME=DIR` options when the same content needs isolated
HTML outputs:

```bash
./zig-out/bin/boris \
  --target docs=dist/docs \
  --target api=dist/api \
  --target-layout docs=themes/docs/layouts/main.html \
  --target-layout api=themes/api/layouts/main.html
```

`--target` is exclusive with `--html-dir`. Page-specific `--layout-rule`
selectors can choose layouts by entity id, glob, or resolved role. Each target
owns its layout, assets, cache, search artifact, and publication evidence.

## Publication families

`plan` inspects a profile. It does not publish. Hosted targets are explicit:

```bash
./zig-out/bin/boris plan --profile boris.json
./zig-out/bin/boris standard-site
./zig-out/bin/boris standard-site plan --profile profiles/standard-site.json
```

GitHub Pages is driven by the official Actions workflow, not a `boris pages`
verb. Standard.site is the `boris standard-site` family. First testers on
bsky.social use `login --app-password`. See
[[guides/publishing|Publishing Targets]].

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Command succeeded; `check` had no failing first-slice policy finding |
| `1` | Content/graph failure, or a failing `check` policy finding |
| `2` | Usage error: unknown flag, missing value, invalid id, or conflicting mode |
| `3` | I/O, allocation, or unexpected system failure |

## Next steps

- [[reference/commands|Command Reference]] — complete CLI surface.
- [[guides/search-and-ui|Search & Browser UI]] — compiler-owned rendered search.
- [[reference/diagnostics|Diagnostics]] — error categories and recovery.
