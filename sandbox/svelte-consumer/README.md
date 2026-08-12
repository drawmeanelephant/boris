# Svelte × Boris — consumer spike

A deliberately small, throwaway experiment answering one question:

> **Can a Svelte/SvelteKit project consume Boris-managed content or Boris
> compiler output cleanly, without requiring Boris to become Svelte-specific?**

**Short answer: yes — and the seam is almost entirely Boris's *existing* IR.**
One genuine gap (rendered bodies) is handled today by an *existing* Boris
mechanism (a `{{content}}`-only layout), with a small, clearly-labeled
consumer-side link rewrite. No Boris code was modified. Nothing here is a
feature request implemented — the deliverables are the working sandbox, this
friction log, and the boundary assessment at the bottom.

Boris owns parsing, validation, identity, relations, graph semantics, and
deterministic rendering. Svelte owns presentation, routing, and client
interaction. This app never re-parses Markdown, never re-resolves wiki-links,
never re-derives roles or edges — every semantic comes from the frozen Boris
IR, and every rendered paragraph comes from a Boris-rendered body fragment.

> Agent handoff: the compressed report for other sessions lives at
> [`docs/spikes/svelte-consumer.md`](../../docs/spikes/svelte-consumer.md).
> Round-2 experiment (interactive overlay, persistence, content-edit rebuild,
> state/content independence, page-local assets):
> [`EXPERIMENT-REPORT.md`](EXPERIMENT-REPORT.md).

---

## 1. What was built

A fully-static SvelteKit app (`@sveltejs/adapter-static`, all routes
prerendered) that consumes two Boris artifacts produced from the **Boris
repo's own real `content/` tree** (45 entities: 7 trunks, 38 satellites —
real includes, wiki-links, asides, tags, statuses):

- **Index page** (`/`) — entity inventory rendered from `manifest.json`
  (compiler, schema version, counts, trunk/satellite forest) plus an
  **interactive client-side search/filter** component (`EntitySearch.svelte`,
  deliberately unrelated to Boris semantics).
- **Detail pages** (`/[...id]`, e.g. `/agents/grok`) — Boris-rendered body
  fragment, breadcrumb, metadata chips (role, status, tags, source path), and
  a **graph relations panel** built from `graph.json`'s typed edges +
  `reverseIndex` + `nav` (parent, children, peers, outgoing references,
  incoming references, includes).
- **Machine-readable endpoints** — `/boris/manifest.json`, `/boris/graph.json`,
  `/boris/build-report.json` are served from the published site.
- **404 page** for unknown entity ids.

Architecture rule respected throughout: Svelte indexes what Boris already
froze; it does not become an authority over content semantics.

## 2. Versions and commit

| Component | Version |
|---|---|
| Boris | `v0.8.0` compiler id `boris/0.8.0`, IR `schemaVersion` `0.2.0`; repo commit `853443c7` |
| Zig | `0.16.0` |
| Svelte | `5.56.1` |
| SvelteKit | `2.63.0` |
| Vite | `8.0.16` |
| Adapter | `@sveltejs/adapter-static` `3.0.10` |
| Node | `22.22.3` |

## 3. Reproduction

### Build Boris content (from the repo root)

```bash
zig build                                   # once — builds the boris binary
bash sandbox/svelte-consumer/boris-data.sh  # or: (cd sandbox/svelte-consumer && npm run data)
```

`boris-data.sh` runs Boris twice against the repo's `content/` tree:

```bash
# 1) IR mode — manifest.json, graph.json, build-report.json
./zig-out/bin/boris --out sandbox/svelte-consumer/data --quiet

# 2) HTML mode with a {{content}}-only layout — one body fragment per entity
./zig-out/bin/boris --html-dir sandbox/svelte-consumer/data/bodies \
  --html-layout sandbox/svelte-consumer/layouts/content-only.html --quiet
```

Two invocations are required because the Boris CLI deliberately keeps HTML and
IR modes exclusive (exit 2 on combination) — see friction F-3.

### Run / build the Svelte app

```bash
cd sandbox/svelte-consumer
npm install
npm run dev        # dev server
npm run build      # prerender -> build/  (reads data/ at build time)
npm run preview    # serve the static build
npm run check      # svelte-check (0 errors / 0 warnings)
```

### Generated vs authored

| Path | Status |
|---|---|
| `sandbox/svelte-consumer/data/**` | **Generated** by Boris (gitignored) |
| `sandbox/svelte-consumer/static/boris/**` | **Generated** — copies of the IR (gitignored) |
| `sandbox/svelte-consumer/build/`, `.svelte-kit/`, `node_modules/` | **Generated** (gitignored) |
| everything else under `sandbox/svelte-consumer/src`, `layouts/`, `boris-data.sh`, configs | **Authored** (spike code) |
| `sandbox/svelte-consumer/layouts/content-only.html` | **Authored** — a 1-line layout, `{{content}}` |

The corpus (`content/`) and the Boris binary are the repo's own; nothing was
invented for Svelte.

### Determinism

Boris output is byte-identical across rebuilds: `sha256sum` of all 45 body
fragments + 3 IR files matched exactly between two full `boris-data.sh` runs
on unchanged input. This is the property a consumer actually needs — the
Svelte build can trust content-addressing and caching.

---

## 4. Friction log

Every awkward step, with the requested shape: *needed → where → glue →
owner → neutral interface that removes it → useful to non-Svelte consumers?*

### F-1. Rendered body HTML does not exist in the IR

- **Needed:** the rendered HTML body of an entity, per entity.
- **Where:** the v0.2 IR contract explicitly omits bodies (`nodes` carry only
  `bodyOffset`; consumers must re-read source). Rendered HTML exists only as
  *full documents* under the HTML output (layout chrome included), or as
  Markdown in the source tree.
- **Glue:** a `{{content}}`-only layout selected via the **existing**
  `--html-layout` flag. Each output file then *is* the body fragment — zero
  extraction, zero layout-coupling. (Attempting to scrape `<main>` out of the
  default full-page layout would have been the fragile alternative; the
  layout swap is strictly better and required no Boris changes.)
- **Owner:** Boris — but only as an *output-surface* matter, not semantics.
  The renderer already exists and is deterministic; it is simply not exposed
  as a per-entity artifact under the IR path.
- **Neutral interface:** a documented "consumer body feed" convention (HTML
  mode + `{{content}}`-only layout) — or, if a second consumer ever shows up,
  a narrow `boris export`-style command emitting `{id}.html` body fragments
  beside the IR in one tree. No new semantics.
- **Useful to non-Svelte consumers?** Yes — Zig, Go, Rust, or vanilla-JS
  renderers that want Apex-rendered bodies without embedding a Markdown
  pipeline or scraping layout chrome would use exactly this feed.

### F-2. Body links are output-relative `*.html` hrefs

- **Needed:** internal links inside bodies that resolve under the consumer's
  routing scheme.
- **Where:** Boris's HTML contract resolves wiki-links to output-relative
  hrefs (`guides/overview.html`, `../index.html`) — correct for a static HTML
  site, wrong for extensionless framework routes.
- **Glue:** ~15 lines in `src/lib/boris/body.ts` (`rewriteInternalLinks`),
  marked **TEMPORARY GLUE**: resolve each relative href against the entity
  id's directory, strip `.html`, emit root-relative route paths. Fragments
  (`#heading-id`) and external links pass through untouched. This rewrite does
  **not** reproduce Boris semantics — it only re-targets hrefs Boris already
  resolved. (A zero-glue alternative exists: make SvelteKit routes tolerate a
  trailing `.html` and strip it in the loader — rejected because it leaks
  `.html` into URLs; the explicit rewrite is more honest and is the thing the
  friction log is for.)
- **Owner:** consumer. Routing is the consumer's domain; Boris's relative-href
  contract is right for the HTML product. The neutral input Boris already
  provides is the **entity id set** (manifest/graph), which is what makes a
  deterministic id→route map possible.
- **Neutral interface:** none required beyond the IR ids. A framework-specific
  "extensionless" href mode in Boris is a **non-recommendation** (below).
- **Useful to non-Svelte consumers?** The same rewrite (relative → consumer
  route) applies to any framework renderer; the glue belongs to each consumer,
  not to Boris.

### F-3. Two CLI invocations for one consumer build

- **Needed:** structure (IR) *and* bodies for one app build.
- **Where:** the CLI keeps HTML and IR modes exclusive (`--out` + `--html`
  → exit 2) — a deliberate mode-selection design, not a bug.
- **Glue:** `boris-data.sh` runs both; trivial for a 45-page tree.
- **Owner:** Boris CLI ergonomics (nothing semantic).
- **Neutral interface:** a single `boris export`-style command that emits a
  coherent consumer tree (IR + body fragments + manifest) would remove this
  for every consumer. Not required by this spike — documented, not built.
- **Useful to non-Svelte consumers?** Yes — any consumer pipeline.

### F-4. The contract is prose, not machine-consumable types

- **Needed:** typed access to the IR from TypeScript.
- **Where:** the normative contract is `docs/contracts/ir-schema.md`
  (documented JSON shape with key order, plus `schemaVersion` for branching).
- **Glue:** a hand-written mirror in `src/lib/boris/types.ts`, annotated with
  the friction note. ~90 lines; needs manual sync on schema changes.
- **Owner:** consumer (types are language-specific) — but see the neutral
  option.
- **Neutral interface:** keep `schemaVersion` branching (already there).
  Optionally ship a JSON Schema alongside the contract one day — that is
  framework-neutral and would let every consumer generate/validate its own
  types. Not built here; not needed for this spike.
- **Useful to non-Svelte consumers?** Yes (validation + codegen for any
  language), which is why it is the *only* typing suggestion that survives the
  neutrality test.

### F-5. Non-issues worth recording (the "easy" side)

- **Canonical IDs:** entity ids are canonical, path-safe, unique, and
  `/`-separated (`identity-and-paths.md`) → **the id *is* the route path**.
  `src/routes/[...id]/+page.svelte` needs zero slug maps or aliases. This is
  the single most valuable property for a framework consumer.
- **Metadata:** title/status/tags/role come straight from `manifest.json` /
  `graph.json` — no transformation.
- **Navigation:** `nav` already contains breadcrumb/children/siblings as
  indices — no recomputation, no re-walk.
- **Relations:** typed `edges` + `reverseIndex` make "referenced from",
  "references", and "includes" trivial index lookups (`src/lib/boris/graph.ts`
  is ~90 lines of pure indexing, zero semantics).
- **Deterministic ordering:** id-ascending order everywhere → stable,
  cacheable, diffable output.
- **Source paths / provenance:** `sourcePath` and `contentRoot` are clean,
  content-relative, machine-friendly.
- **Incremental-build behavior:** Boris's `--incremental` is HTML-path only
  and a consumer regenerates IR+bodies with two full runs; for this tree it is
  instant. For huge trees a watch bridge would be nice — a consumer-side
  concern, not a Boris semantic gap.
- **Assets:** the corpus has no page-local assets; content-local assets would
  need the same relative-href re-targeting as F-2. Predicted friction,
  not exercised — flagged, not blocking.

---

## 5. Does the evidence support a minimum consumer contract?

**Yes — but it is tiny, and most of it already exists.** What the experiment
actually consumed:

| Concept | Source | Friction |
|---|---|---|
| entity id | `manifest.json` / `graph.json` (`id`) | none — id == route |
| metadata | manifest (`title`, `status`, `role`, `parent`) | none |
| graph/relations | `graph.json` (`nav`, `edges`, `reverseIndex`) | none |
| navigation | `graph.json` (`nav`) | none |
| rendered body | **not in IR** — content-only HTML layout | the only real gap (F-1) |
| output route | derived from id (`{id}.html` → `/id`) | none (F-2 is hrefs *inside* bodies) |
| assets | content-local `{stem}.assets/` | not exercised; predicted F-2-style |

The minimum framework-neutral consumer contract is therefore:

> **IR (manifest + graph) for structure, plus a per-entity rendered-body feed
> keyed by entity id.**

That is two sentences of semantics. A tiny Zig/Go/Rust/vanilla renderer would
want exactly the same two things, and Boris already produces both — the IR
verbatim, and the bodies via a `{{content}}`-only layout. What is missing is
not a semantic concept but an *output-surface convenience* (F-3) and a
documented convention for the body feed (F-1).

Everything else the experiment touched — TS types, link rewriting, route
mapping — is consumer-side and should stay consumer-side.

## 6. Where should the boundary live?

**Recommendation: a small existing-output convention, not a new API.**

The evidence does not justify inventing a `boris export` capability today:
one consumer exists (this throwaway), and the seam works end-to-end with zero
Boris changes. The cheapest correct step is to *document* the convention the
spike discovered:

> A framework-neutral consumer feed = Boris IR (`--out`) + HTML mode with a
> `{{content}}`-only layout (`--html-layout`), both generated from the same
> content root; consumers map entity ids to their own routes and re-target
> internal `*.html` hrefs.

That is a docs-level note (STATUS/changelog-fragment territory), not a
contract or schema change.

**If a second consumer ever appears** (or the two-invocation dance starts to
bite), the next smallest capability is a narrow `boris export`-style command
that emits, in one deterministic tree: the IR files, `{id}.html` body
fragments, and the manifest — **no new semantics, no framework concepts, no
content-in-IR**. That would absorb F-1 and F-3 at once and remain
framework-neutral.

## 7. Non-recommendations (things Boris should NOT absorb)

Attractive ideas investigated and deliberately declined, per the neutrality
test ("would a Zig/Go/Rust/vanilla renderer want this too?"):

1. **No rendered bodies inside `graph.json` / `manifest.json`.** IR stays
   lean metadata + graph; bodies already have a home in the HTML path. Adding
   them would balloon the IR and duplicate the renderer's job.
2. **No TS types / `.d.ts` packages in Boris.** Language-specific. (A neutral
   JSON Schema could come later; not required now.)
3. **No "extensionless" or root-absolute href mode in the HTML contract.**
   The relative-href contract is correct for the static site; the consumer
   rewrite is 15 lines and stays consumer-side.
4. **No `index.html`-to-bare-URL rewriting, slug maps, or alias tables** in
   Boris for framework convenience — ids are already canonical and
   route-ready.
5. **No Svelte/Boris frontend SDK package.** The entire consumer seam is
   three small files; formalizing it would imply more boundary than exists.
6. **No second identity model.** Svelte consumes Boris ids verbatim.
7. **No re-implementation of Boris parsing/relation resolution in Svelte**
   (e.g., a JS Markdown renderer over the source tree) — that would make
   Svelte a second authority and silently fork rendering. The whole point of
   the body feed is to keep Apex as the single renderer.

## 8. Next smallest experiment

Two candidates, both cheap:

1. **The interactive-overlay experiment** (matches the stated goal of games in
   websites): take one Boris entity and mount a genuinely interactive Svelte
   component (canvas demo/quiz) next to its Boris-rendered body via this same
   seam. Test the full loop — edit Markdown → `npm run data` → rebuild — and
   confirm the interactive UI survives content updates untouched. This is the
   "rich UI coexists with managed content" claim under real churn.
2. **The non-Svelte cross-check:** a ~50-line Zig or vanilla-JS script that
   consumes the same IR + body feed, to validate that the proposed boundary
   really is framework-neutral and not accidentally Svelte-shaped.

Do the interactive-overlay experiment first; it directly tests the reason
this exploration was started.
