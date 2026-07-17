# Migrating an existing docs site to Boris

This guide is the **first real site** path: inventory → convert a bounded
slice → review reports → compile HTML / IR / RAG → exercise authoring
features → incremental edit → prod vs preview → deploy the static tree.

It is **content and process** guidance — not a second compiler dialect and
not a change to product contracts.

| Artifact | Role |
|----------|------|
| This guide | Author-facing adoption sequence |
| [`fixtures/migration-site/`](../fixtures/migration-site/) | Contoso conversion fixture (~32 pages + theme) |
| [`examples/reference-theme/`](../examples/reference-theme/) | Optional theme dogfood (Aside, Details, page-local assets, layout rules) |
| [`tools/migration-lab/`](../tools/migration-lab/) | Standalone **developer laboratories** (drafts + reports) |
| [`README.md`](../README.md) | Product front door + five-minute build |

---

## Who does what (read once)

| Layer | Owns | Does not own |
|-------|------|--------------|
| **Boris product** (`./zig-out/bin/boris`) | Validated Trunk/Satellite graph; HTML under a target dir; IR; RAG; Context Bundle; fail-loud wiki/includes/components | Universal import; link-checking ordinary `[]()` hrefs; analytics; hosting |
| **Migration labs** (`boris-migration-lab`) | Read-only inventory / draft Markdown + preservation reports for named source shapes | Runtime dependency of `boris`; full site parity; network fetch |
| **Manual human review** | Frontmatter closure, graph shape, link rewrite, asset placement, theme trust, deploy choice | Automatic “done” from a green lab report |
| **Future / unimplemented** | Full YAML/MDX, embedded HTTP server, universal Astro/MkDocs/Hugo importers, automatic analytics | Claimed in this guide |

```text
Old site inventory
      │
      ├─(optional lab)→ draft Markdown + reports   ← developer aid
      │
      ▼
Human review against non-negotiables               ← manual
      │
      ▼
Closed frontmatter + Trunk/Satellite + wiki/includes
      │
      ▼
  boris ──► HTML | IR | RAG | Context Bundle       ← product
      │
      ▼
Static output dir → any static host                ← deployment (outside Boris)
```

---

## Non-negotiables (before bulk conversion)

1. **Closed frontmatter** — only `id`, `title`, `parent`, `status`, `tags`.
2. **Parent key is `parent` only** — `parentEntry` / `parent_entry` fail as
   unknown keys on the product parser. The Filed migration lab rewrites those
   legacy keys to `parent` under `--out` only (with conflict/invalid review);
   see [`tools/migration-lab/README.md`](../tools/migration-lab/README.md) and
   [`docs/dogfood/filed-parent-key-normalize.md`](dogfood/filed-parent-key-normalize.md).
   Do not expect product `boris` to accept the aliases.
3. **One-level graph** — Satellites parent to **Trunks** only (no
   satellite-of-satellite).
4. **Entity ids** — path-derived (or `id:` override); case- and byte-exact for
   `parent` and `[[wiki-links]]`.
5. **Includes** — `{{include path}}` relative to content root; prefer
   `includes/` (not discovered as pages).
6. **Wiki links** — `[[entity-id]]` and `[[entity-id#heading-id]]`; heading
   fragments must match Apex-rendered ids exactly. Wiki entity ids use an
   **ASCII** character class — prefer ASCII path stems for linkable pages.
   Missing wiki targets **fail the build**. Ordinary Markdown
   `[text](./page.md)` hrefs are **not** fully validated as a site-wide link
   checker.
7. **Examples stay fenced** — put sample wiki/include/Aside syntax in fenced
   code blocks. Inline backticks do not protect wiki/include directives; bare
   `<Aside …>` / `<Details …>` outside fences are real components.
8. **Themes** — trusted static HTML layouts + copied `assets/`; no CDN fetch
   in the compile path. Page-local media uses sibling `<stem>.assets/` only.
9. **UTF-8 without BOM** — BOM rejects the file.

Normative detail: [`docs/contracts/`](contracts/).

---

## First real site path

All commands below assume a **clean checkout** of this repository, run from
the **repository root**, after building the product binary once.

```bash
zig build
./zig-out/bin/boris --help   # optional orientation
```

Host tools to build Boris itself: **Zig 0.16** + **CMake** (CMake is
compile-time for vendored ApexMarkdown only). Authors who already have
`zig-out/bin/boris` do not need Node to publish docs.

Exit codes for product `boris`: **0** ok · **1** content · **2** usage · **3** I/O.

Write experimental outputs under `test-output/…` (gitignored) or another
ignored path **inside** the workspace. Boris rejects workspace-escaping
output dirs. Do not commit generated HTML, IR, RAG, caches, or `dist/`.

### 1. Inspect a source tree

**Product behavior:** none yet — this step is inventory only.

**Manual human review:** export a ledger before moving files:

- Every Markdown (or convertible) path
- Nav / sidebar hierarchy
- Shared snippets / partials
- Internal link style (`[x](../a.md)`, `@site`, `ref`, wiki, etc.)
- Theme assets (CSS, fonts, images) vs page-owned media
- Frontmatter keys in use

**Migration-lab developer aid (optional):** for a *named* source shape with a
committed mini fixture, build and run the standalone lab. Labs never rewrite
inputs and never install into the product `boris` binary.

```bash
# From repository root — Starlight dogfood fixture (~60 synthetic pages)
zig build --build-file tools/migration-lab/build.zig
zig build --build-file tools/migration-lab/build.zig run -- \
  --mode=starlight \
  --root=tools/migration-lab/fixtures/dogfood-starlight \
  --out=test-output/lab-starlight-inspect \
  --locale=en \
  --max-pages=80
```

```bash
# Astro archaeology (report only — no Boris content tree claimed complete)
zig build --build-file tools/migration-lab/build.zig run -- \
  --mode=astro \
  --root=tools/migration-lab/fixtures/mini-astro \
  --out=test-output/lab-astro-inspect
```

Other lab modes (WordPress WXR, Instagram Takeout, Obsidian, Notion, Filed)
and flags: [`tools/migration-lab/README.md`](../tools/migration-lab/README.md).

**Real-site dogfood (Filed.fyi first slice):** a bounded pass against a live
Filed.fyi checkout — inventory, lab modes, product HTML/IR/RAG, remediation
cards, and a narrow RC recommendation — is recorded in
[`docs/dogfood/filed-fyi-adoption-pass.md`](dogfood/filed-fyi-adoption-pass.md).
A second pass with a five-page representative slice (landing, nested docs,
page-local asset, absolute links, hard MDX dialects) is in
[`docs/dogfood/filed-fyi-v051-representative-slice.md`](dogfood/filed-fyi-v051-representative-slice.md).
Both are evidence for humans, not universal converter claims.

**What to open after a lab run:** `REPORT.md` / `report.json` (and mode-specific
manifests under the `--out` dir). Treat them as **evidence for the human
ledger**, not as a green light to skip non-negotiables.

If you are not converting an external tree, skip the lab and use the Contoso
fixture as your practice source in step 2.

### 2. Convert or author a bounded Markdown slice

**Product behavior:** Boris compiles only trees that already satisfy closed
frontmatter and Trunk/Satellite rules.

**Manual:** either (a) hand-convert a small section, or (b) take lab draft
Markdown and fix it until it matches the non-negotiables.

**Recommended first slice shape:**

```text
your-site/
  content/           # pages + includes/
  theme/             # layouts/, footer.html, assets/
```

For experiments **in this repository**, do **not** replace root `content/`
(product dogfood). Practice against:

| Tree | Use when |
|------|----------|
| `fixtures/migration-site/` | Contoso migration (~32 pages): wiki, includes, Aside, deep paths, multi-target |
| `examples/reference-theme/` | Polished theme surface: Details, page-local `.assets/`, multi-layout rules |

Minimal satellite:

```markdown
---
title: Getting started
parent: guides
status: published
tags: [guides]
---
```

Minimal trunk (section landing — no `parent`):

```markdown
---
title: Guides
status: published
tags: [guides]
---
```

**Convert checklist for the slice**

| Old mechanism | Boris |
|---------------|-------|
| Nested YAML / unknown keys | Drop or keep outside the source tree |
| Section parent | `parent: <trunk-entity-id>` |
| Snippets / partials | `{{include includes/….md}}` |
| Admonition plugins | `<Aside kind="tip">…</Aside>` |
| Collapsible FAQ / digressions | `<Details summary="…">…</Details>` |
| `[Text](../guides/foo.md)` | `[[guides/foo\|Text]]` |
| Heading anchors from another SSG | Build once; copy rendered `id` into `[[id#heading]]` |
| Shared static media | Theme `assets/` + `{{asset-url assets/…}}` |
| Page-owned diagram next to a page | Sibling `page.assets/file.svg` + Markdown image |

**Future / unimplemented:** there is no product flag that imports MkDocs
`nav:`, Docusaurus sidebars, or full MDX components. Preprocess out of band
or convert manually.

### 3. Review preservation / migration reports

**Migration lab:** open the lab `--out` directory and confirm every
preserve / drop / rewrite decision is intentional.

**Manual human review (required even when the lab is green):**

- [ ] Only `id`, `title`, `parent`, `status`, `tags` remain in page frontmatter
- [ ] Every Satellite `parent` names a Trunk entity id (byte-exact)
- [ ] No satellite-of-satellite edges
- [ ] Includes live under content-root `includes/` when possible
- [ ] Wiki targets use entity ids, not `.md` paths
- [ ] Page-local media uses exact sibling `<stem>.assets/` (not a global media library)
- [ ] Theme layouts contain exactly one `{{content}}` and only trusted HTML
- [ ] Lab “converted” pages that still carry MDX/JS are rewritten or deferred

**Product (optional read-only health on a Boris tree):** after the first
successful HTML build (step 4), you may run:

```bash
./zig-out/bin/boris \
  check \
  --input fixtures/migration-site/content \
  --format human
```

Unreferenced-page findings can exit **1** without meaning the HTML compile
failed earlier — treat `check` as a **policy report**, not a substitute for
exit `0` on the compile itself. For JSON handoff:

```bash
./zig-out/bin/boris \
  check \
  --input fixtures/migration-site/content \
  --format json \
  --report test-output/migration-check.json
```

### 4. Build HTML, page-local assets, IR, and RAG

Modes do **not** mix: one invocation is HTML **or** IR **or** RAG **or**
Context Bundle.

#### 4a. Contoso migration fixture — HTML

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --theme fixtures/migration-site/theme \
  --html-dir test-output/migration-dist \
  --quiet

echo $?   # expect 0
```

**Expected (product HTML)**

| Check | Result |
|-------|--------|
| Exit code | `0` |
| Deployable site root | `test-output/migration-dist/` |
| Home | `test-output/migration-dist/index.html` |
| Deep page | `…/guides/deep/nested/path/note.html` |
| Theme CSS | `…/assets/css/site.css` |
| Theme image | `…/assets/img/mark.svg` |
| Includes as pages | **None** — `includes/` not emitted |

Spot-check: no raw `[[entity]]` left in body prose; CSS `href`s are
page-relative.

#### 4b. Reference theme — HTML + page-local assets + layout rules

Use this when you need Details, sibling `.assets/`, and multi-layout selection
in one copy-paste command:

```bash
./zig-out/bin/boris \
  --input examples/reference-theme/content \
  --theme examples/reference-theme/theme \
  --layout-rule default id:index \
    examples/reference-theme/theme/layouts/home.html \
  --layout-rule default role:trunk \
    examples/reference-theme/theme/layouts/section.html \
  --html-dir test-output/reference-theme \
  --quiet

echo $?   # expect 0
```

**Expected**

| Artifact | Expectation |
|----------|-------------|
| Exit code | `0` |
| `test-output/reference-theme/index.html` | `data-layout="home"` |
| Trunk landings | `data-layout="section"` |
| Satellites | `data-layout="main"` (fallback theme layout) |
| Page-local SVG | `…/index.assets/rhythm-diagram.svg`, `…/guides/components.assets/component-flow.svg` |
| Theme CSS / mark | under `…/assets/` |

Offline check (should print nothing):

```bash
rg -n 'https?://' test-output/reference-theme --glob '*.html' || true
```

#### 4c. JSON IR

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --out test-output/migration-ir \
  --quiet
```

**Expected:** exit `0` and `manifest.json`, `graph.json`, `build-report.json`
under `test-output/migration-ir/`.

#### 4d. RAG pack

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --rag-dir test-output/migration-rag \
  --quiet
```

**Expected:** exit `0`; corpus under the rag-dir (`INDEX.md`, `catalog.jsonl`,
… per product help). Do not commit.

#### 4e. Context Bundle (optional)

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --context-dir test-output/migration-context \
  --quiet
```

Upload `bundle.md` (or the directory) as **grounded context** for an LLM —
not as a substitute for source control or the HTML site. Contract:
[context-bundle.md](contracts/context-bundle.md).

### 5. Use Aside, Details, includes, wiki-links, heading links, and layout rules

This step is **product authoring surface**. Prefer reading live pages in the
fixtures rather than inventing a second tutorial tree.

| Feature | Product syntax / flag | Where to see it working |
|---------|----------------------|-------------------------|
| Aside | `<Aside kind="tip">…</Aside>` | `fixtures/migration-site/content/guides/asides.md`; reference `guides/components.md` |
| Details | `<Details summary="…">…</Details>` | `examples/reference-theme/content/guides/components.md` |
| Includes | `{{include includes/….md}}` | `fixtures/migration-site/content/guides/includes.md` |
| Wiki page links | `[[entity-id]]` / `[[entity-id\|label]]` | `…/guides/wiki-links.md` |
| Wiki heading links | `[[entity-id#heading-id]]` | `…/guides/heading-fragments.md` |
| Layout rules | `--layout-rule TARGET SELECTOR PATH` | Step 4b command; selectors `id:`, `glob:`, `role:` |

**After the reference-theme HTML build (4b), spot-check:**

```bash
rg -n 'admonition--|class="details"|page-children|page-toc|site-nav|index.assets|components.assets' \
  test-output/reference-theme/index.html \
  test-output/reference-theme/guides.html \
  test-output/reference-theme/guides/components.html

rg -n 'data-layout=' \
  test-output/reference-theme/index.html \
  test-output/reference-theme/guides.html \
  test-output/reference-theme/guides/getting-started.html
```

**Layout rule notes (product):**

- Rules are **HTML-only** — they do not change frontmatter, IR, RAG, or Context Bundle.
- Selectors: `id:<entity-id>`, `glob:<segment-pattern>`, `role:trunk|satellite`.
- One managed theme root per target; fallback layout is `--theme` /
  `--target-layout` / `--html-layout`.
- Contract: [templating-and-themes.md](contracts/templating-and-themes.md).

**Page-local assets (product):** sibling `intro.assets/diagram.svg` next to
`intro.md`; Markdown image `![alt](intro.assets/diagram.svg)` is rewritten to
a published page-relative URL. Not a global media library. Contract:
[content-local-assets.md](contracts/content-local-assets.md).

**Manual:** keep examples of these syntaxes in **fenced** code blocks on
migration notes pages so they are not executed.

### 6. Run an incremental edit

**Product:** `--incremental` skips unchanged HTML pages using
content-addressed fingerprints (and shared reverse dependency semantics for
includes / wiki material).

Full baseline (once), then incremental:

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --theme fixtures/migration-site/theme \
  --html-dir test-output/migration-dist \
  --quiet

./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --theme fixtures/migration-site/theme \
  --html-dir test-output/migration-dist \
  --incremental \
  --quiet
```

**Manual practice edit** (local only — revert or leave uncommitted):

1. Change a sentence in `fixtures/migration-site/content/guides/getting-started.md`.
2. Re-run the `--incremental` command above.
3. Confirm exit `0` and that `test-output/migration-dist/guides/getting-started.html`
   reflects the edit.
4. Optionally restore the file if you do not want a dirty tree.

Cache may appear under `test-output/migration-dist/.boris-cache/` (local /
untracked). After bulk renames, run a **full** HTML build once before relying
on incremental again.

Optional parallel HTML workers on the same tree:

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --theme fixtures/migration-site/theme \
  --html-dir test-output/migration-dist \
  --jobs 4 \
  --incremental \
  --quiet
```

### 7. Compare production and preview targets

**Product:** multi-target HTML isolates output roots, staging trees, and cache
namespaces. Same content tree; no shared incremental cache between targets.

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --target prod=test-output/migration-prod \
  --target preview=test-output/migration-preview \
  --target-layout prod=fixtures/migration-site/theme/layouts/main.html \
  --target-layout preview=fixtures/migration-site/theme/layouts/main.html \
  --quiet

echo $?   # expect 0
ls test-output/migration-prod/index.html
ls test-output/migration-preview/index.html
```

**Manual comparison:**

- Both trees should contain the same entity HTML paths for this fixture.
- Theme assets are copied **per target**.
- You may later give `preview` different `--layout-rule` / layout paths without
  changing content frontmatter.
- Do **not** use one target’s `.boris-cache` as another’s.

**Future / unimplemented:** Boris does not deploy, promote, or sync targets
to a host. Promotion is “point the host at the prod directory you built.”

### 8. Identify the static output directory for deployment

| Build style | Static site root to publish |
|-------------|-----------------------------|
| Default repo dogfood (`boris --quiet`) | `dist/` |
| Contoso fixture (`--html-dir …`) | The directory you passed (e.g. `test-output/migration-dist/`) |
| Reference theme (`--html-dir …`) | e.g. `test-output/reference-theme/` |
| Multi-target prod | The **prod** target dir (e.g. `test-output/migration-prod/`) |

**Product behavior:** that directory is ordinary static files (`*.html`,
copied theme `assets/`, page-local `*.assets/`). There is **no** embedded
Boris HTTP server and **no** Node runtime required at serve time.

**Manual deployment:** copy or rsync that directory to any static host, or
serve locally with any static file server of your choice. Open
`index.html` at the site root (or configure the host’s default document).

Do **not** publish intermediate trees such as `*.boris-stage`, IR `--out`
dirs, RAG dirs, or Context Bundle dirs as the public docs site unless you
intentionally want those artifacts.

### 9. Add analytics only as an explicit theme / deployment choice

**Product behavior:** Boris has **no** analytics flag, plugin, or hosted
beacon. Compile-time theme asset copy does **not** fetch CDNs.

**Manual (explicit choice — trusted HTML only):**

1. **Theme injection** — edit a layout under `theme/layouts/` (or `footer.html`
   spliced via `{{footer}}`) and add a first-party or vendor snippet you
   accept as trusted HTML. Raw HTML in layouts and Markdown is **passed
   through** ([apex-abi](contracts/apex-abi.md) trust model).
2. **Host / CDN injection** — configure the static host to inject a script
   without touching the Boris tree.

**Do not:**

- Treat analytics as part of migration success criteria
- Expect labs or `boris` to preserve third-party tag managers from Astro/MkDocs
- Add Node packaging “for analytics build steps” as a Boris dependency

Example shape only (illustrative — not enabled in fixtures):

```html
<!-- theme/layouts/main.html, inside <head> or before </body> — your choice -->
<script defer src="{{asset-url assets/js/analytics.js}}"></script>
```

Prefer a **self-hosted** script under `theme/assets/` if you need offline /
air-gapped builds. A remote `https://…` script URL works only at **browser**
time; it is not fetched during `boris` compile. Keep network beacons out of
the default product dogfood trees unless you deliberately accept them.

---

## Your own tree (after the fixture path)

```bash
./zig-out/bin/boris \
  --input path/to/content \
  --theme path/to/theme \
  --html-dir test-output/my-docs-dist \
  --quiet
```

Default product dogfood (repo `content/` + `layouts/main.html` → `dist/`):

```bash
./zig-out/bin/boris --quiet
```

Optional multi-layout on your tree:

```bash
./zig-out/bin/boris \
  --input path/to/content \
  --target public=test-output/my-docs-dist \
  --target-layout public=theme/layouts/main.html \
  --layout-rule public id:index theme/layouts/home.html \
  --layout-rule public 'glob:reference/*' theme/layouts/reference.html \
  --layout-rule public role:trunk theme/layouts/section.html \
  --quiet
```

Post-cutover health:

```bash
./zig-out/bin/boris check --input path/to/content --format human
./zig-out/bin/boris impact <entity-id> --input path/to/content
```

---

## Rename / move checklist

Use after cutover when paths or titles change.

### Before

- [ ] Capture current entity ids (from paths or `graph.json`).
- [ ] Grep for `parent:` values that name trunks you will rename.
- [ ] Grep for `[[old-id` wiki links (including `#fragments`).
- [ ] List include paths that will move.

### During

- [ ] Move/rename Markdown files **or** set temporary `id:` overrides.
- [ ] Update Trunk `parent` references.
- [ ] Update wiki links and heading fragments.
- [ ] Update `{{include …}}` paths if fragments moved.
- [ ] Prefer `{{asset-url}}` over hand-maintained `../` asset hrefs.
- [ ] Keep page-local media as a sibling `<stem>.assets/` when the page moves.

### After

- [ ] Full HTML build (no `--incremental`) → exit `0`.
- [ ] Grep for retired ids → zero hits in active content.
- [ ] Open a deep page; confirm CSS/img/page-local assets load.
- [ ] Optional IR build; confirm node set in `graph.json`.
- [ ] Re-enable `--incremental` / `--watch` for daily authoring.

### Common failure → fix

| Exit / symptom | Fix |
|----------------|-----|
| `EFRONTMATTER` unknown key | Remove/rename key; use `parent` only |
| Missing parent | Point `parent` at a Trunk entity id |
| Satellite of satellite | Reparent to a Trunk |
| `EREFERENCEMISSING` page | Fix entity id spelling/case |
| `EREFERENCEMISSING` heading | Copy Apex `id` from rendered HTML/TOC |
| `EINCLUDEMISSING` | Fix include path relative to content root |
| `ECOMPONENT` / invalid Details/Aside | Stick to closed component grammar |
| `EASSET` | Fix page-local path; stay inside `<stem>.assets/` |
| `EINVALIDUTF8` | Strip BOM; fix encoding |
| Exit `2` | Remove conflicting mode flags |

---

## Mapping cheat sheets

### MkDocs Material preflight

Treat a completed MkDocs Material site as conversion evidence, not as a Boris
input tree. **`mkdocs.yml`, the Material theme/plugin runtime, Python hooks,
and full YAML metadata are not Boris inputs.** Boris does not import that
configuration or execute its plugins/hooks, and this guide does not promise a
general MkDocs importer.

Before moving files, make a small manual conversion ledger:

- [ ] **Closed frontmatter:** map only `id`, `title`, `parent`, `status`, and
  `tags`; remove or preserve elsewhere every other YAML key. In particular,
  Material/blog `authors`, `date`, `categories`, and blog-specific metadata
  need an authoring or publishing decision outside Boris's source grammar.
  See the [frontmatter contract](contracts/frontmatter.md).
- [ ] **Navigation:** use `mkdocs.yml` only as an inventory, then flatten each
  nested `nav:` branch into a Trunk landing page plus direct Satellite pages.
  A Satellite cannot parent another Satellite; see the
  [parent/graph rules](contracts/ir-schema.md#trunk--satellite-graph-rules).
- [ ] **Links:** replace relative Markdown page links such as
  `[Install](../setup.md)` with `[[setup|Install]]` (and validate any heading
  fragment against the rendered heading id). The exact include/wiki syntax and
  failure behavior are in the [includes and wiki-links contract](contracts/includes-and-wiki-links.md).
- [ ] **Reusable Markdown:** replace plugin- or hook-expanded snippets with
  explicit `{{include includes/name.md}}` directives; keep fragments under the
  content-root `includes/` directory rather than treating them as pages.
- [ ] **Local assets:** inventory every image, download, font, and stylesheet
  referenced by content. Theme static bytes go under `theme/assets/`;
  page-owned media goes under sibling `<stem>.assets/`. Check a deep generated
  page for working URLs. See [templating and themes](contracts/templating-and-themes.md)
  and [content-local assets](contracts/content-local-assets.md).
- [ ] **Runtime features:** replace Material plugins, macros, Python hooks,
  generated navigation, and blog/archive behavior with static Markdown,
  explicit includes, a bounded Boris theme, or a separate pre-conversion step.
  Do not pass their configuration through as frontmatter.

Run a full Boris HTML build after this pass and fix validation errors before
porting visual polish. That proves the converted content graph; it does not
claim Material feature parity.

### Hugo

| Hugo | Boris |
|------|-------|
| Section menus | Trunk landing + `parent` |
| Shortcodes | Include / Aside / Details / Markdown |
| `static/` | Theme `assets/` and/or page-local `.assets/` |
| `ref` / `relref` | `[[entity-id]]` |

### MkDocs

| MkDocs | Boris |
|--------|-------|
| `nav:` tree | Trunk / Satellite forest |
| Snippets | `{{include}}` |
| `!!!` admonitions | `<Aside>` |
| Plugins/macros | Preprocess out of band |

### Docusaurus

| Docusaurus | Boris |
|------------|-------|
| Sidebars | Trunk / Satellite |
| MDX components | Strip; static only (Aside / Details / include) |
| `@site` links | Wiki entity ids |
| `static/` | Theme assets / page-local assets |

More narrative recipes: fixture pages under
`fixtures/migration-site/content/cookbook/`.

---

## What not to commit

Keep generated and local tooling output **untracked**:

| Path / pattern | Why |
|----------------|-----|
| `dist/`, custom `--html-dir` trees | Generated HTML |
| `rag/`, `--rag-dir` trees | Generated corpus |
| `.boris/`, IR `--out` dirs | Generated IR |
| `.boris-cache/`, target caches | Incremental state |
| `source-rag/` | Generated source pack |
| `context/`, custom `--context-dir` trees | Generated AI Context Bundle |
| Lab `--out` dirs under `test-output/` | Drafts + reports |
| `zig-out/`, `.zig-cache/` | Build outputs |

Repository `.gitignore` already covers common product output roots such as
`dist/`, `rag/`, and `test-output/`.

---

## Fixture coverage matrix

| Concern | Where |
|---------|-------|
| 20–40 pages | `fixtures/migration-site/content/` (~32 pages) |
| Trunk / Satellite | Section landings + children |
| Includes | `content/includes/*` + live `{{include}}` |
| Wiki links | Guides / reference throughout |
| Heading fragments | `guides/heading-fragments.md` |
| Aside | `guides/asides.md` |
| Details + page-local assets + layout rules | `examples/reference-theme/` |
| Layouts + theme assets | Each fixture’s `theme/` |
| Unicode | `special/cafe-notes.md` (ASCII path, wiki-linkable) |
| Deep paths | `guides/deep/nested/path/note.md` |
| Case-sensitive IDs | `special/CaseDemo.md`, `reference/HTTP-status.md` |
| Multi-target / incremental notes | `ops/` pages + this guide steps 6–7 |
| Rename checklist | This doc + `cookbook/rename-pages.md` |
| Lab inspect / convert drafts | `tools/migration-lab/` (developer aid) |

---

## Verification while developing Boris itself

When you only touch content, layouts, assets, and docs (as with this guide):

```bash
# Contoso HTML smoke
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --theme fixtures/migration-site/theme \
  --html-dir test-output/migration-dist \
  --quiet

# Reference theme smoke (Details, assets, layout rules)
./zig-out/bin/boris \
  --input examples/reference-theme/content \
  --theme examples/reference-theme/theme \
  --layout-rule default id:index \
    examples/reference-theme/theme/layouts/home.html \
  --layout-rule default role:trunk \
    examples/reference-theme/theme/layouts/section.html \
  --html-dir test-output/reference-theme \
  --quiet

zig build test
# optional broader gate when convenient:
./scripts/release-gate.sh
```

The migration fixture and reference theme are **not** required by the release
gate; they are authoring and conversion aids. Root `zig build test` does **not**
include `tools/migration-lab/`; after lab code changes run:

```bash
zig build --build-file tools/migration-lab/build.zig test
```

---

## Related reading

| Doc | Role |
|-----|------|
| [`fixtures/migration-site/README.md`](../fixtures/migration-site/README.md) | Contoso fixture how-to |
| [`examples/reference-theme/README.md`](../examples/reference-theme/README.md) | Theme dogfood commands |
| [`tools/migration-lab/README.md`](../tools/migration-lab/README.md) | Standalone labs |
| [`README.md`](../README.md) | Product front door + CLI |
| [`docs/STATUS.md`](STATUS.md) | Current phase |
| [`docs/contracts/frontmatter.md`](contracts/frontmatter.md) | Normative FM grammar |
| [`docs/contracts/includes-and-wiki-links.md`](contracts/includes-and-wiki-links.md) | Includes + wiki |
| [`docs/contracts/heading-ids.md`](contracts/heading-ids.md) | Fragment ids |
| [`docs/contracts/components.md`](contracts/components.md) | Aside / Details |
| [`docs/contracts/content-local-assets.md`](contracts/content-local-assets.md) | Page-local `.assets/` |
| [`docs/contracts/templating-and-themes.md`](contracts/templating-and-themes.md) | Themes + layout rules |
| [`docs/contracts/parent-relationships.md`](contracts/parent-relationships.md) | Graph parents |
| [`docs/contracts/multi-target-isolated-output.md`](contracts/multi-target-isolated-output.md) | Prod / preview isolation |
