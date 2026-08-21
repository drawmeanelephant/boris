# Source map

One page. Where the code lives. Not a function catalog.

Normative behavior is still [`docs/contracts/`](contracts/). This map is a
hallway: it names the rooms. Open the `.zig` file if you need the furniture.

## How to read `src/`

The compiler is one binary. Files cluster by job, not by fashion.

| If you are looking for… | Start here | Contract |
|---|---|---|
| Argv, commands, exit codes | `src/cli.zig`, `src/main.zig`, `src/init.zig` | [cli.md](contracts/cli.md) |
| Discover pages | `src/scanner.zig`, `src/identity.zig`, `src/source_io.zig`, `src/source_provider.zig` | [scanner.md](contracts/scanner.md), [identity-and-paths.md](contracts/identity-and-paths.md), [source-provider.md](contracts/source-provider.md) |
| Frontmatter and the page record | `src/parser.zig`, `src/page.zig` | [frontmatter.md](contracts/frontmatter.md) |
| Graph, parents, edges | `src/graph.zig`, `src/dependency.zig`, `src/pipeline.zig` | [ir-schema.md](contracts/ir-schema.md) |
| Wiki-links, includes, doc links | `src/wikilink.zig`, `src/include.zig`, `src/doclink.zig` | [includes-and-wiki-links.md](contracts/includes-and-wiki-links.md), [documentation-links.md](contracts/documentation-links.md) |
| Aside / Details | `src/aside.zig` | [components.md](contracts/components.md) |
| Oliver render | `src/render.zig` | [oliver-renderer.md](contracts/oliver-renderer.md) |
| Freestanding render Wasm | `src/render_wasm.zig`, `src/wasm_image.zig` | [embedding.md](contracts/embedding.md) |
| In-memory compileBundle | `src/embed.zig`, `src/embed_evidence.zig` | [embedding.md](contracts/embedding.md) |
| compileBundle Wasm ABI | `src/embed_wasm.zig` | [embedding.md](contracts/embedding.md) |
| Cloudflare Worker host example | `hosts/cloudflare-worker/` | [embedding.md](contracts/embedding.md) |
| Cooklang recipe scale | `src/recipe_scale.zig`, `src/recipe_scale_view.zig` | [cooklang-compatibility.md](contracts/cooklang-compatibility.md), [cli.md](contracts/cli.md) |
| HTML body, nav, TOC, assemble | `src/html_body.zig`, `src/html_nav.zig`, `src/html_toc.zig`, `src/assemble.zig`, `src/compile.zig` | [html-output.md](contracts/html-output.md) |
| Themes, layouts, assets | `src/theme.zig`, `src/layout_select.zig`, `src/content_asset.zig` | [templating-and-themes.md](contracts/templating-and-themes.md), [content-local-assets.md](contracts/content-local-assets.md) |
| Incremental / watch / jobs | `src/cache.zig`, `src/watch.zig`, `src/timings.zig` | [watch-mode.md](contracts/watch-mode.md), [parallel-rendering.md](contracts/parallel-rendering.md) |
| IR / RAG / Context / llms.txt | `src/ir_emit.zig`, `src/rag.zig`, `src/rag_emit.zig`, `src/context.zig`, `src/llms.zig`, `src/artifact_sink.zig` | [ir-schema.md](contracts/ir-schema.md), [rag-export.md](contracts/rag-export.md), [context-bundle.md](contracts/context-bundle.md), [llms-txt.md](contracts/llms-txt.md), [artifact-sink.md](contracts/artifact-sink.md) |
| RSS / sitemap / search | `src/rss.zig`, `src/sitemap.zig`, `src/search_index.zig` | [rss-2.0.md](contracts/rss-2.0.md), [xml-sitemap.md](contracts/xml-sitemap.md), [rendered-search.md](contracts/rendered-search.md) |
| Publication profile / plan / evidence | `src/publication_profile.zig`, `src/publication_plan.zig`, `src/artifact_inventory.zig`, `src/publication_checks.zig`, `src/publication_claims.zig`, `src/publication_touches.zig`, `src/publication_proof_pack.zig` | [publication-profile.md](contracts/publication-profile.md) through [publication-proof-pack.md](contracts/publication-proof-pack.md) |
| GitHub Pages | `src/github_pages.zig` | [github-pages.md](github-pages.md) |
| Standard.site / AT Protocol | `src/standard_site*.zig`, `src/atproto_*.zig` | [standard-site.md](standard-site.md), [contracts/standard-site.md](contracts/standard-site.md) |
| Nostr NIP-23 | `src/nostr.zig`, `src/nostr_plan.zig`, `src/nostr_sign.zig`, `src/nostr_publish.zig`, `src/nostr_keys.zig`, `src/nostr_emit.zig`, `src/ws_client.zig` | [nostr-publication.md](contracts/nostr-publication.md) |
| Diagnostics | `src/diag.zig`, `src/diagnostic.zig` | [diagnostics.md](contracts/diagnostics.md) |
| Graph health | `src/intelligence.zig` | [documentation-intelligence.md](contracts/documentation-intelligence.md) |
| Doctor | `src/doctor.zig` | Internal snapshot kernel only. No public `boris doctor` command. |
| Hosted job runner (Cloudflare Containers) | `src/job_runner.zig` (`boris-job-runner`) | [cloudflare-container-runner.md](contracts/cloudflare-container-runner.md) |

Outside `src/`:

Editor
: [`editor/`](../editor/) — local host. Compiler stays the authority.

Cloudflare Worker host example
: [`hosts/cloudflare-worker/`](../hosts/cloudflare-worker/) — HTTP/R2 glue around the embed Wasm ABI. Not a publication target.

Migration labs / source-RAG / search-index / docs-maintenance
: [`tools/`](../tools/) — standalone. Not linked into the `boris` binary.

## Documentation map

Moved from [`docs/STATUS.md`](STATUS.md) per
[#692](https://github.com/drawmeanelephant/boris/issues/692) — `STATUS.md` is
now a phase banner + pointer table. The capability snapshot lives in
[`docs/archived/capability-matrix-v0.8.md`](archived/capability-matrix-v0.8.md).
`CHANGELOG.md` was slimmed per
[#691](https://github.com/drawmeanelephant/boris/issues/691) — pre-0.8 history
at [`docs/archived/CHANGELOG-pre-0.8.md`](archived/CHANGELOG-pre-0.8.md).

| Document | Use it for |
|---|---|
| [`README.md`](../README.md) | Product outcomes and quick start |
| [`docs/contracts/`](contracts/) | Normative compiler and artifact behavior |
| [`docs/contracts/publication-model.md`](contracts/publication-model.md) | Canonical ownership of document facts, publication facts, migration provenance, projections, and verification claims |
| [`docs/contracts/publication-platforms.md`](contracts/publication-platforms.md) | Target registry and verified-target adapter seam |
| [`CHANGELOG.md`](../CHANGELOG.md) | Released-history record (`[Unreleased]` + `[0.8.0]`; pre-0.8 at [`CHANGELOG-pre-0.8.md`](archived/CHANGELOG-pre-0.8.md)) |
| [`docs/changelog.d/`](changelog.d/) | Pending release fragments |
| [`docs/archived/CHANGELOG-pre-0.8.md`](archived/CHANGELOG-pre-0.8.md) | Archived pre-0.8 history (pre-slim, not standing context) |
| [`docs/MIGRATION.md`](MIGRATION.md) | Bounded author migration workflow |
| [`docs/authoring-spine.md`](authoring-spine.md) | Teaching path from `boris init` to publish + verify |
| [`tools/migration-lab/README.md`](../tools/migration-lab/README.md) | Standalone migration-lab commands |
| [`tools/search-index/README.md`](../tools/search-index/README.md) | Rendered search tool |
| [`docs/github-pages.md`](github-pages.md) | GitHub Pages setup, location model, workflow, and evidence boundary |
| [`docs/cloudflare-container.md`](cloudflare-container.md) | Hosted runner + Cloudflare Containers example (not a target) |
| [`docs/standard-site.md`](standard-site.md) | Standard.site first-tester path |
| [`docs/RELEASE-GATE.md`](RELEASE-GATE.md) | Mechanical ship checks |
| [`AGENTS.md`](../AGENTS.md) | Repository policy and agent constraints |
| [`content/`](../content/) | Compiled public documentation site (Oliver-rendered) |
| [`docs/SOURCE-MAP.md`](SOURCE-MAP.md) | Where `src/` clusters live. Not a function catalog. |
| [`docs/archived/capability-matrix-v0.8.md`](archived/capability-matrix-v0.8.md) | Archived v0.8 capability snapshot (pre-slim) |
| [`docs/archived/CHANGELOG-pre-0.8.md`](archived/CHANGELOG-pre-0.8.md) | Archived pre-0.8 changelog (pre-slim, not standing context) |

## Rules

- Do not grow a per-function prose twin of `src/` or `tools/`. Those
  dossier trees were retired. Operator docs for labs live in
  [`tools/migration-lab/README.md`](../tools/migration-lab/README.md) and
  [`tools/source-rag/README.md`](../tools/source-rag/README.md).
   Historical dogfood reports and retrospectives were retired; the v0.8
   capability snapshot lives in
   [`docs/archived/capability-matrix-v0.8.md`](archived/capability-matrix-v0.8.md)
   and `STATUS.md` is now a phase banner + pointer table (see #692);
   pre-0.8 history is at
   [`docs/archived/CHANGELOG-pre-0.8.md`](archived/CHANGELOG-pre-0.8.md)
   and `CHANGELOG.md` keeps only `[Unreleased]` + `[0.8.0]` (see #691).
- A new module does not require a new Markdown file here. Add a row when
  the *job* is new.
- If this page and a contract disagree, the contract wins. If this page
  and `src/` disagree, `src/` wins and this page should be edited.
