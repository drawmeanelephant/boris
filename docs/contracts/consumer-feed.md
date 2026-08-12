# External consumer feed — IR + rendered body fragments

**Status:** normative description of the **existing** output surface for
external consumers. It specifies **no new compiler behavior** — every surface
below is already normative in [ir-schema.md](ir-schema.md),
[html-output.md](html-output.md), [identity-and-paths.md](identity-and-paths.md),
and [content-local-assets.md](content-local-assets.md). This document exists
because two independent consumers (a SvelteKit app and a zero-dependency
vanilla renderer — see [Evidence](#7-evidence-non-normative)) demonstrated that
Boris's existing output is a sufficient, framework-neutral boundary, and the
conventions below are now relied upon.

The boundary in one sentence: **Boris emits verified knowledge (IR: structure,
metadata, relations, graph) plus per-entity rendered body fragments; the
consumer supplies presentation, routing, and application behavior.** Neither
system becomes authoritative over the other's semantics.

---

## 1. Scope

| In scope | Out of scope |
|----------|--------------|
| `manifest.json`, `graph.json`, `build-report.json` under `--out` | Bodies inside IR (IR carries `bodyOffset` only — see [ir-schema.md](ir-schema.md)) |
| Per-entity rendered body fragments via HTML mode with a `{{content}}`-only layout | A dedicated `boris export` command (none exists; none is needed) |
| Output-relative href convention in bodies | TypeScript declarations (consumers hand-own type mirrors if they want them) |
| Content-local page assets (`{entity_id}.assets/`) | Extensionless-href output mode (does not exist; see [Section 4](#4-conventions-a-consumer-can-rely-on)) |
| Deterministic rebuilds | Browser/application state, server persistence, or any runtime behavior |

## 2. Recipe (two commands, existing flags)

```bash
# 1. IR — structure, metadata, relations, graph
boris --out <ir-dir> --quiet

# 2. Rendered bodies — per-entity HTML fragments via a {{content}}-only layout
boris --html-dir <bodies-dir> --html-layout <path/to/content-only.html> --quiet
```

Two invocations are required because the CLI keeps HTML and IR modes
**exclusive**: combining `--out` with `--html-dir` (or `--target`) is a usage
error (exit 2). This is an ergonomics constraint of the existing CLI, not a
semantic one — both invocations validate the same graph and fail the build
(exit 1) on any content error.

The `{{content}}`-only layout is a normal user-authored layout containing
exactly the required `{{content}}` marker (see
[templating-and-themes.md](templating-and-themes.md) and the layout rules in
[html-output.md](html-output.md)); `--layout-rule` may select per-role or
per-id layouts the same way it does for full-site builds. **Nothing in this
recipe is Svelte-specific** — the layouts are framework-neutral HTML.

## 3. Artifacts

### IR (`--out <DIR>`)

| File | Content | Canonical |
|------|---------|-----------|
| `manifest.json` | `schemaVersion`, `compiler`, `contentRoot`, `pageCount`, `pages[]` (index, id, sourcePath, role, parent, title, status) | [ir-schema.md](ir-schema.md) |
| `graph.json` | `frozen: true`, `nodes[]` (+ `parentIndex`, `tags`, `bodyOffset`), `edges[]` (typed: `parent` / `include` / `reference`), `reverseIndex[]`, `nav[]` (breadcrumb / children / siblings by node index) | [ir-schema.md](ir-schema.md) |
| `build-report.json` | `schemaVersion`, `ok`, `contentRoot`, `outDir`, `pageCount`, `errorCount`, `diagnostics[]` | [ir-schema.md](ir-schema.md) |

All files are deterministic JSON in canonical field order; identical inputs
produce byte-identical files.

### Body feed (HTML mode, `{{content}}`-only layout)

Each entity publishes one file at its output path:

```text
<out>/<entity_id>.html      # e.g. guides/overview.html, agents/antigravity.html
```

The file **is the rendered body fragment**: the layout's static prefix/suffix
are empty around the single `{{content}}` marker, so the emitted file is the
Apex-rendered body (includes expanded, wiki-links resolved to relative `.html`
hrefs, asides rendered — see [html-output.md](html-output.md) and
[includes-and-wiki-links.md](includes-and-wiki-links.md)). The entity id maps
one-to-one to the output path stem
([identity-and-paths.md](identity-and-paths.md)).

### Assets

Content-local page assets publish as a sibling directory and are referenced by
rewritten page-relative `src` URLs:

```text
<out>/<entity_id>.assets/...   # content-local-assets.md
```

See [content-local-assets.md](content-local-assets.md) for discovery,
rewriting, and copy rules.

## 4. Conventions a consumer can rely on

1. **Entity id is the identity and the route.** `manifest.pages[].id`,
   `graph.nodes[].id`, and the body file `<entity_id>.html` all agree. No
   slug maps, no second identity model.
2. **Body fragments are fragments, not documents.** They carry no
   `<html>`/`<head>`/`<body>` shell; the consumer supplies the document shell
   (as it would for any partial).
3. **Body hrefs are output-relative.** Every internal link resolves relative
   to the published page's *directory* (e.g. `guides/overview.html` links to
   `trunk-satellite.html`, `agents/antigravity.html` links to `../agents.html`,
   and heading links carry `#fragment` suffixes). Consumers have two clean
   options:
   - **Adopt the output paths** (route = `<entity_id>.html`): every href
     resolves with **zero rewrite** — this is the natural choice for a static
     renderer, and the vanilla cross-check consumer proves it end-to-end.
   - **Re-target to framework routes** (e.g. SvelteKit's extensionless,
     root-relative routes): the consumer rewrites hrefs by path. This is
     consumer-side, framework-specific glue — Boris deliberately emits no
     extensionless hrefs.
4. **Rebuilds are deterministic.** Unchanged inputs produce byte-identical IR
   and body files (verified for both consumers).
5. **Relations are already resolved and typed.** `graph.edges` + `reverseIndex`
   give outgoing and incoming references, includes, and parents without the
   consumer re-parsing source or re-deriving semantics; `graph.nav` gives
   breadcrumb / children / siblings. Index them; do not recompute them.

## 5. What belongs to the consumer (not Boris)

- The document shell and all presentation/styling.
- Route adoption or re-targeting (Section 4, item 3).
- Copying/serving content-local assets if the consumer's static server does
  not already serve `<entity_id>.assets/` trees from the feed directory.
- Application state, browser persistence, and interaction — including when
  that interaction borrows the canonical entity id as an opaque storage key.

## 6. Non-claims (explicit)

- **No bodies in IR.** The IR never carries rendered body HTML — only
  `bodyOffset`. Consumers get bodies from the HTML-mode feed.
- **No `boris export`.** No dedicated consumer-export command exists or is
  planned from this evidence; the recipe in [Section 2](#2-recipe-two-commands-existing-flags)
  is the surface.
- **No extensionless-href mode.** The `.html` output-relative href convention
  is the contract; framework-specific route re-targeting is consumer glue.
- **No TypeScript declarations in Boris.** Consumers hand-own type mirrors if
  they want them.
- **No asset serving, no browser state, no runtime behavior** in Boris.

## 7. Evidence (non-normative)

Two independent consumers validated this feed against the repository's real
`content/` tree (45 entities, 191 typed edges), both with **zero Boris
changes**:

- **SvelteKit consumer** (`sandbox/svelte-consumer/`): structure/metadata/
  relations from IR; bodies from the feed; ~15 lines of route re-targeting
  glue plus a ~7-line asset-copy step — both consumer-side. Handoff:
  [docs/spikes/svelte-consumer.md](../spikes/svelte-consumer.md).
- **Vanilla renderer** (`sandbox/svelte-consumer/cross-check/render.mjs`):
  zero-dependency Node script rendering the same feed at output paths — 626
  internal links resolved with **zero rewrite**; output byte-identical across
  runs. Report:
  [docs/spikes/svelte-consumer.md](../spikes/svelte-consumer.md) (round 4).

Both consumers verified deterministic rebuilds and untouched content when the
other half changed.

## 8. Related

- [ir-schema.md](ir-schema.md) — JSON IR shape (manifest, graph, build-report)
- [html-output.md](html-output.md) — HTML path, layout splice, `{{content}}`
- [identity-and-paths.md](identity-and-paths.md) — entity id → `{id}.html`
- [content-local-assets.md](content-local-assets.md) — `{entity_id}.assets/`
- [templating-and-themes.md](templating-and-themes.md) — layout rules and
  `--layout-rule` / `--html-layout`
- [includes-and-wiki-links.md](includes-and-wiki-links.md) — href rewriting
