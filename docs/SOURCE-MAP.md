# Source map

One page. Where the code lives. Not a function catalog.

Normative behavior is still [`docs/contracts/`](contracts/). This map is a
hallway: it names the rooms. Open the `.zig` file if you need the furniture.

## How to read `src/`

The compiler is one binary. Files cluster by job, not by fashion.

| If you are looking for… | Start here | Contract |
|---|---|---|
| Argv, commands, exit codes | `src/cli.zig`, `src/main.zig`, `src/init.zig` | [cli.md](contracts/cli.md) |
| Discover pages | `src/scanner.zig`, `src/identity.zig`, `src/source_io.zig` | [scanner.md](contracts/scanner.md), [identity-and-paths.md](contracts/identity-and-paths.md) |
| Frontmatter and the page record | `src/parser.zig`, `src/page.zig` | [frontmatter.md](contracts/frontmatter.md) |
| Graph, parents, edges | `src/graph.zig`, `src/dependency.zig`, `src/pipeline.zig` | [ir-schema.md](contracts/ir-schema.md) |
| Wiki-links, includes, doc links | `src/wikilink.zig`, `src/include.zig`, `src/doclink.zig` | [includes-and-wiki-links.md](contracts/includes-and-wiki-links.md), [documentation-links.md](contracts/documentation-links.md) |
| Aside / Details | `src/aside.zig` | [components.md](contracts/components.md) |
| Oliver render | `src/render.zig` | [oliver-renderer.md](contracts/oliver-renderer.md) |
| HTML body, nav, TOC, assemble | `src/html_body.zig`, `src/html_nav.zig`, `src/html_toc.zig`, `src/assemble.zig`, `src/compile.zig` | [html-output.md](contracts/html-output.md) |
| Themes, layouts, assets | `src/theme.zig`, `src/layout_select.zig`, `src/content_asset.zig` | [templating-and-themes.md](contracts/templating-and-themes.md), [content-local-assets.md](contracts/content-local-assets.md) |
| Incremental / watch / jobs | `src/cache.zig`, `src/watch.zig`, `src/timings.zig` | [watch-mode.md](contracts/watch-mode.md), [parallel-rendering.md](contracts/parallel-rendering.md) |
| IR / RAG / Context / llms.txt | `src/ir_emit.zig`, `src/rag.zig`, `src/rag_emit.zig`, `src/context.zig`, `src/llms.zig` | [ir-schema.md](contracts/ir-schema.md), [rag-export.md](contracts/rag-export.md), [context-bundle.md](contracts/context-bundle.md), [llms-txt.md](contracts/llms-txt.md) |
| RSS / sitemap / search | `src/rss.zig`, `src/sitemap.zig`, `src/search_index.zig` | [rss-2.0.md](contracts/rss-2.0.md), [xml-sitemap.md](contracts/xml-sitemap.md), [rendered-search.md](contracts/rendered-search.md) |
| Publication profile / plan / evidence | `src/publication_profile.zig`, `src/publication_plan.zig`, `src/artifact_inventory.zig`, `src/publication_checks.zig`, `src/publication_claims.zig`, `src/publication_touches.zig`, `src/publication_proof_pack.zig` | [publication-profile.md](contracts/publication-profile.md) through [publication-proof-pack.md](contracts/publication-proof-pack.md) |
| GitHub Pages | `src/github_pages.zig` | [github-pages.md](github-pages.md) |
| Standard.site / AT Protocol | `src/standard_site*.zig`, `src/atproto_*.zig` | [standard-site.md](standard-site.md), [contracts/standard-site.md](contracts/standard-site.md) |
| Nostr (open program) | `src/nostr.zig`, `src/nostr_plan.zig` | issue [#454](https://github.com/drawmeanelephant/boris/issues/454) |
| Diagnostics | `src/diag.zig`, `src/diagnostic.zig` | [diagnostics.md](contracts/diagnostics.md) |
| Graph health | `src/intelligence.zig` | [documentation-intelligence.md](contracts/documentation-intelligence.md) |
| Doctor | `src/doctor.zig` | Internal snapshot kernel only. No public `boris doctor` command. |

Outside `src/`:

Editor
: [`editor/`](../editor/) — local host. Compiler stays the authority.

Migration labs / source-RAG / search-index / docs-maintenance
: [`tools/`](../tools/) — standalone. Not linked into the `boris` binary.

## Rules

- Do not grow a per-function prose twin of `src/` or `tools/`. Those
  dossier trees were retired. Operator docs for labs live in
  [`tools/migration-lab/README.md`](../tools/migration-lab/README.md) and
  [`tools/source-rag/README.md`](../tools/source-rag/README.md).
- A new module does not require a new Markdown file here. Add a row when
  the *job* is new.
- If this page and a contract disagree, the contract wins. If this page
  and `src/` disagree, `src/` wins and this page should be edited.
