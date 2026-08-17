# Boris

**The Content Exit Hatch**

Boris is a graph-native publication compiler. It turns Markdown into a
validated content graph, then publishes that graph to one or more contracted
targets. HTML `dist/` is the default target, not the whole product.

Write content locally. Build with one native binary. Inspect the output. Ship
it to a static host, to GitHub Pages, to Standard.site, or to a machine
projection — from the same frozen graph.

[Authoring spine](docs/authoring-spine.md) ·
[Status](docs/STATUS.md) ·
[Contracts](docs/contracts/) ·
[GitHub Pages](docs/github-pages.md) ·
[Standard.site](docs/standard-site.md) ·
[Migration](docs/MIGRATION.md)

## What Boris does

```text
Markdown + closed frontmatter
          │
          ▼
 discover → validate graph → freeze
          │
          ├── HTML site                 (default: dist/)
          ├── GitHub Pages              (verified target)
          ├── Standard.site / AT Proto  (verified target)
          ├── Nostr NIP-23              (plan → sign → publish; not verified)
          ├── JSON IR                   (--out)
          ├── RAG / Context / llms.txt  (--rag / --context / --llms)
          └── RSS 2.0 / XML sitemap     (--rss / --sitemap)
```

The content model is deliberately small: **Trunks** are root pages,
**Satellites** are explicitly parented non-root pages (including nested parent
chains), and in-page `Aside`/`Details` blocks stay in document order. Broken
parents, wiki-links, headings, includes, and cycles fail with diagnostics
instead of quietly producing a broken site.

Publication is a **registry**, not a shell recipe. GitHub Pages and
Standard.site are verified targets. Nostr NIP-23 is a shipped CLI family
(`boris nostr plan` / `sign` / `publish`) and is **not** a verified target:
no location adapter, no Proof Pack, no live-smoke gate. The local
[Boris Editor](content/guides/editor.md) is a compiler-backed authoring
surface, not a second product.

## Features

- Native Markdown through the pinned **Oliver** library (Zig, in-process):
  CommonMark, GFM tables, heading ids/IAL, footnotes, definition lists,
  strikethrough.
- Deterministic HTML output with trusted static layouts and copied assets.
- Validated Trunk/Satellite navigation and graph-aware breadcrumbs/children.
- Closed, explicit frontmatter rather than unrestricted YAML or executable MDX.
- Authoritative `boris validate` preflight with no generated output or evidence.
- Incremental builds, watch mode, isolated targets, and bounded page workers.
- JSON IR with typed dependency edges and reverse indexes.
- Deterministic RAG, Context Bundle, `llms.txt`, and RSS 2.0 exports from the same tree.
- Deterministic staged XML sitemap for one public HTML target.
- First-class GitHub Pages publication identity and an official verified Actions workflow.
- Standard.site / AT Protocol publication: offline plan + explicit login/publish/smoke.
  The first-tester path against bsky.social is an app password, not browser OAuth.
- Nostr NIP-23 long-form publication: offline `nostr plan → sign`, then
  `nostr publish` delivers the exact signed events over a bounded RFC-6455
  client with per-relay `complete`/`partial`/`failed`/`incomplete` evidence.
  Not a verified target.
- Target-local evidence chain: artifacts → checks → claims → Touch Atlas → Proof Pack.
- Local Boris Editor: schema-aware completion, compiler-backed problems, live preview.
- Standalone migration labs for Astro/Starlight, WordPress, Instagram, Obsidian,
  Notion, and related source shapes.

## Why Boris?

Most documentation stacks are also JavaScript application toolchains. Boris
takes a narrower path: a local Zig binary that treats documentation as a
validated content graph rather than a folder full of unrelated pages. That
means fewer moving parts in the publishing path, explicit failure when the
structure is wrong, and several machine-readable outputs without maintaining a
second content model.

Boris is not trying to replace every SSG. It is for people who want a small,
inspectable compiler, graph-aware documentation, and more than one honest
place to put the result — without requiring a Node runtime to publish the site.

## Nostr NIP-23 publication

Pages allowlisted in the profile can be published to the Nostr network as
NIP-23 long-form-content events. The pipeline keeps the secret and the
network strictly apart:

```text
boris nostr plan --profile PROFILE.json        # offline: plan JSON on stdout
boris nostr sign --plan PLAN.json --key-stdin  # offline: key once via stdin, bundle out
boris nostr publish --plan PLAN.json --bundle BUNDLE.json  # online: exact signed events to relays
```

- **`nostr plan`** is the only profile-selection step; it never reads a key,
  signs, or contacts a relay.
- **`nostr sign`** is the only command that reads a secret — the key (64 hex
  digits or a NIP-19 `nsec`) is read once from stdin and never accepted from
  argv, a profile, an environment variable, or a log. It signs the exact
  NIP-01 event IDs with BIP-340 Schnorr signatures (bitcoin-core/secp256k1,
  pinned and verified) and writes a signed-event bundle.
- **`nostr publish`** never sees a key. It verifies the bundle against the
  plan offline, then sends the exact signed events to the plan's relays over
  a bounded in-repo RFC-6455 client (`wss://`; `ws://` only for loopback
  test relays). Every relay interaction is bounded and recorded: the report
  classifies the run `complete` / `partial` / `failed` / `incomplete` with
  per-relay evidence, and a relay that demands NIP-42 authentication is
  reported honestly as unsupported rather than silently skipped.

A bare `boris build` never needs a key, a relay, or the network, and a failed
Nostr operation never invalidates a committed website. The normative
[`nostr-publication` contract](docs/contracts/nostr-publication.md) specifies
the plan, signed-bundle, and report artifacts; the CLI surface is in
[`cli.md`](docs/contracts/cli.md).

## Quick start

Building Boris requires [Zig 0.16+](https://ziglang.org/) only. Markdown
rendering is Oliver, a pure-Zig library pinned by content hash in
`build.zig.zon` and fetched by Zig at build time; it is not part of the
authoring or publishing workflow.

```bash
git clone https://github.com/drawmeanelephant/boris.git
cd boris
zig build
./zig-out/bin/boris --quiet
```

The sample content is compiled to `dist/`. Open `dist/index.html` or serve the
directory with any static file server.

That is the whole default path. New to authoring? The
[authoring spine](docs/authoring-spine.md) is the teaching path from
`boris init` to a published, verified site. It names the publish targets
without pretending they are the first command.

Useful first commands:

```bash
./zig-out/bin/boris --help
./zig-out/bin/boris --version                 # print the compiler id (e.g. boris/0.8.1)
./zig-out/bin/boris --out .boris --quiet       # JSON IR
./zig-out/bin/boris --rag --quiet              # RAG working-context packs
./zig-out/bin/boris --rag --complete --quiet    # complete-corpus RAG export
./zig-out/bin/boris --context --quiet          # AI Context Bundle
./zig-out/bin/boris --rag-dir ./uploads/rag --scope mascots --split-size 262144
./zig-out/bin/boris --context-dir ./uploads/context --scope mascots/genny --split-size 131072
./zig-out/bin/boris --llms --quiet             # llms.txt
./zig-out/bin/boris --rss --site-url https://docs.example/ --rss-title "Example Docs" --rss-description "Recent updates" --quiet
./zig-out/bin/boris --sitemap --site-url https://docs.example/ --quiet
./zig-out/bin/boris validate --quiet             # HTML source/config preflight; no output
./zig-out/bin/boris check                      # graph-health report
./zig-out/bin/boris impact getting-started    # dependency impact report
./zig-out/bin/boris plan --profile boris.json  # normalized publication declaration
zig build test
```

### Publication targets (not the default path)

The repository’s GitHub Pages publication path is documented in
[`docs/github-pages.md`](docs/github-pages.md). It uses the native Boris
compiler, keeps proof reports in a retained evidence artifact, and uploads
only the exact public files declared by the target inventory.

Atmosphere publication (Standard.site records on an AT Protocol PDS) is a
separate, explicit family: `boris standard-site`. First testers should start
at [`docs/standard-site.md`](docs/standard-site.md). Offline plan/verify
need no credentials; live publish against bsky.social uses
`login --app-password`, not the browser OAuth path.

Nostr NIP-23 is `boris nostr plan` → `sign` → `publish`. The secret never
meets the network. It is not a verified target. Operator path:
[`content/guides/nostr-publication.md`](content/guides/nostr-publication.md).

The local editor is a separate binary:

```bash
zig build --build-file editor/build.zig
./editor/zig-out/bin/boris-editor . \
  --boris ./zig-out/bin/boris \
  --ui-dir editor/ui/dist
```

### Add a page

Create a Markdown file under `content/`:

```markdown
---
title: My first satellite
parent: getting-started
status: published
tags: [guides]
---

# My first satellite

Ship docs with one binary.
```

The author-facing parent key is `parent`. Legacy names such as `parentEntry`
and `parent_entry` are intentionally rejected; see the
[frontmatter contract](docs/contracts/frontmatter.md).

### Working-context RAG packs

The default `--rag` export is a **working context**: a small number of bounded
upload files containing the selected site documents (frontmatter, H1s,
`<Aside>` / `<Details>` authoring syntax preserved) and the required site graph
closure — never the `docs/rag/system` corpus — plus a `manifest.json` sidecar
that is **not meant to be uploaded**. Attachment count and context size are
first-class constraints; integrity records live in the sidecar, not in the
model-facing files.

```bash
# Working context for the whole site (bounded packs + sidecar)
./zig-out/bin/boris --rag --rag-dir ./uploads/rag

# Scoped working context: the subtree, its parents, and one-hop neighbors
./zig-out/bin/boris --rag-dir ./uploads/rag/mascots --scope mascots

# Explicit complete-corpus export (system + per-page + graph + catalog)
./zig-out/bin/boris --rag --complete --rag-dir ./uploads/rag-complete

# Single-record Context Bundle with complete pages plus upload parts
./zig-out/bin/boris --context-dir ./uploads/context/genny \
  --scope mascots/028.genny-compileheart --split-size 131072
```

After a working export Boris prints what you actually need to know: selected
pages, structural parents and semantic neighbors pulled in, the exact upload
file paths, approximate bytes and tokens, and the `manifest.json` sidecar
identified separately as a non-upload file. `--complete` is the explicit
full-corpus export (system + per-page + graph + catalog) and rejects `--scope`:
complete means the entire validated corpus.

`--split-size` is the working-pack target in bytes (default 262144), not a
model token estimate — and whole documents are never split merely to meet it;
only a single document larger than the target is split, at safe Markdown
paragraph or heading boundaries outside fenced code. An indivisible block
larger than the target fails without replacing an existing export. See the
[RAG export contract](docs/contracts/rag-export.md).

## Outputs from one content tree

| Command | Output | Best for |
| --- | --- | --- |
| `boris` | HTML under `dist/` | Default static-site target |
| `boris validate` | None | Compiler-authoritative HTML source/configuration preflight |
| `boris --sitemap --site-url URL` | HTML plus `sitemap.xml` | Crawler URL discovery |
| `boris --out .boris` | JSON IR | Build tools and inspection |
| `boris --rag` | Working-context packs | LLM site authoring (bounded uploads) |
| `boris --rag --complete` | Complete RAG corpus | Full-tree LLM retrieval and audits |
| `boris --context` | Context Bundle | Provenance-rich agent context |
| `boris --llms` | `llms.txt` | Lightweight machine discovery |
| `boris --rss` | RSS 2.0 XML | Recent documentation updates |
| `boris plan --profile PATH` | Normalized declaration JSON | Inspect a publication target before publishing |
| `boris standard-site …` | Atmosphere records | Standard.site / AT Protocol target |
| `boris nostr plan` / `sign` / `publish` | NIP-23 events + per-relay report | Nostr long-form; not a verified target |

The machine exports are separate output modes from the same source tree; they
do not silently merge into one opaque build product. Sitemap is the exception
shown explicitly above: it is an HTML-build flag, not a separate content projection.
`--sitemap-path PATH` changes its target-relative path and implies
`--sitemap`. A sitemap is a discovery hint, not a guarantee that a search
engine will crawl or index a page.

`boris validate` follows the normal HTML compiler through its bounded
prepublication render phases, then stops before creating a target or stage.
It is distinct from `check`, which adds graph-health policy, and from normal
build publication/evidence. See the
[validation contract](docs/contracts/validation.md) for the exact boundary.

The canonical [publication model](docs/contracts/publication-model.md) defines
which values are document facts, publication facts, migration provenance, or
projection evidence. Selecting or emitting one output does not merge its
contract with another output or prove deployment correctness.

RSS is opt-in and does not modify themes. After publishing `rss.xml`, add this
standard discovery hint to a layout when the deployed feed URL is known:

```html
<link rel="alternate" type="application/rss+xml" title="Feed title" href="/rss.xml">
```

## Benchmarking

Boris performance should be measured on a stated machine, toolchain, content
tree, optimization mode, and worker count. A single fast run is not a
benchmark.

No committed benchmark harness exists yet (see
[`docs/audits/optimization-audit.md`](docs/audits/optimization-audit.md));
until one lands, numbers in issues and audits should name the machine,
toolchain, content tree, optimization mode, and worker count they were
measured with.

## Migration

Migration is a workflow, not a promise of one-click conversion:

```text
inspect → select a bounded slice → preserve/propose/review
       → compile HTML + IR → inspect the result → expand carefully
```

The migration labs are standalone developer aids. They can inventory source
trees, identify relationships and unsupported constructs, materialize reviewed
themes, and produce manual-review reports. They do not add Astro, Node, or an
MDX runtime to Boris core.

Start with [`docs/MIGRATION.md`](docs/MIGRATION.md). Current lab state is
the Labs table in [`docs/STATUS.md`](docs/STATUS.md).

## AI and OpenAI Build Week

Boris was built through continuous human–AI collaboration using ChatGPT 5.6,
Codex, delegated implementation, hostile testing, migration audits, and
deliberate scope cuts. AI accelerated exploration and execution; the project’s
contracts, boundaries, acceptance decisions, and final merges remained
human-steered.

The `--context`, `--rag`, `--llms`, and `--rss` modes are practical parts of the product,
not hosted AI services. They emit local, deterministic artifacts that can be
reviewed or uploaded to an LLM when useful.

## Roadmap

- [x] Deterministic HTML, JSON IR, graph validation, and native Oliver Markdown.
- [x] Incremental/watch builds, bounded jobs, multi-target output, and assets.
- [x] RAG, Context Bundle, `llms.txt`, RSS 2.0, and XML sitemap exports.
- [x] GitHub Pages verified target and official Actions workflow.
- [x] Standard.site / AT Protocol first-tester path (app-password on bsky.social).
- [x] Publication evidence chain (artifacts, checks, claims, Touch Atlas, Proof Pack).
- [x] Local Boris Editor (compiler-backed authoring).
- [x] Migration labs and real-site dogfood evidence.
- [x] v0.8.1 candidate packaging (untagged; 200+ changelog fragments queued).
- [ ] Archive-layout browser review and any evidence-gated presentation fixes.
- [ ] Standard.site HTML verification-surface emit ([#533](https://github.com/drawmeanelephant/boris/issues/533)).
- [x] Nostr NIP-23 CLI (`plan` / `sign` / `publish`). Not a verified target.
- [x] Embeddable `compileBundle` (native + Wasm) and an example Cloudflare Worker host ([#301](https://github.com/drawmeanelephant/boris/issues/301) M0–M7). Not a verified target. Live Cloudflare smoke and isolate-peak measurement remain open on the parent issue.
- [x] Cloudflare container hosted runner ([#300](https://github.com/drawmeanelephant/boris/issues/300)). Example only; not a verified target.

Current phase and known gaps live in [`docs/STATUS.md`](docs/STATUS.md).

## Honest limitations

- Zig 0.16+ is required to build Boris itself.
- Frontmatter is intentionally closed; Boris is not a general YAML parser.
- Unrestricted MDX and executable JavaScript components are out of scope.
- Raw HTML is trusted input and is not sanitized by default.
- Ordinary Markdown links are not a complete site-wide link checker.
- Migration labs are bounded aids, not universal importers.
- Cross-platform byte identity and speed claims require measured evidence.
- Standard.site browser OAuth is implemented but unusable on bsky.social
  (`site.standard.authFull` is not granted). Use an app password.
- Production HTML does not yet emit Standard.site verification surfaces.

## Project map

- [`docs/STATUS.md`](docs/STATUS.md) — identity, current phase, and known gaps
- [`docs/SOURCE-MAP.md`](docs/SOURCE-MAP.md) — where `src/` clusters live
- [`docs/contracts/`](docs/contracts/) — normative behavior
- [`docs/authoring-spine.md`](docs/authoring-spine.md) — init → publish → verify
- [`docs/MIGRATION.md`](docs/MIGRATION.md) — migration workflow
- [`docs/github-pages.md`](docs/github-pages.md) — Pages target
- [`docs/standard-site.md`](docs/standard-site.md) — Atmosphere target
- [`docs/RELEASE-GATE.md`](docs/RELEASE-GATE.md) — release checks
- [`tools/migration-lab/`](tools/migration-lab/) — standalone migration tools
- [`tools/source-rag/`](tools/source-rag/) — source-code RAG exporter
- [`tools/content-audit/`](tools/content-audit/) — standalone deterministic source-content audit tool
- [`editor/`](editor/) — local compiler-backed editor
- [`themes/`](themes/) — shipped first-class themes
- [`examples/`](examples/) — sample sites and unfinished theme studies
- [`CHANGELOG.md`](CHANGELOG.md) — release history

## License

Boris is released under the [MIT License](LICENSE).
