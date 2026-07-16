# Migrating an existing docs site to Boris

This guide is for authors and tech writers converting a Markdown documentation
site into Boris. It is **content and process** guidance — not a second compiler
dialect and not a change to product contracts.

Companion fixture (realistic Contoso tree, ~32 pages + theme):

[`fixtures/migration-site/`](../fixtures/migration-site/)

Product front door and five-minute build: [`README.md`](../README.md).

---

## What is real today

| Path | What it is | What it is not |
|------|------------|----------------|
| **This guide + fixture** | Manual conversion into Boris's closed content model, then `boris` compile | An automatic importer for every SSG |
| **`boris` product binary** | HTML / IR / RAG / Context Bundle from a Boris tree; fail-loud graph + wiki | A Node SSG, universal link checker, or plugin host |
| **`tools/migration-lab/`** | Standalone **developer laboratories** (Astro archaeology, WordPress WXR, Instagram Takeout, Obsidian, Notion, Starlight, …) | A runtime dependency of `boris`, or a promise of full site parity |

Labs never rewrite your originals, do not fetch the network, and are built from
[`tools/migration-lab/`](../tools/migration-lab/) — not from the product
`boris` CLI. Treat lab output as a **starting draft** to review under this
guide's non-negotiables, then compile with product `boris`.

```text
Old site inventory
      │
      ├─(optional lab)→ draft Markdown + reports
      │
      ▼
Closed frontmatter + Trunk/Satellite + wiki/includes
      │
      ▼
  boris ──► HTML | IR | RAG | Context Bundle
```

---

## What you are migrating into

Boris is a **Zig documentation compiler**:

| Input | Output (choose **one** mode) |
|-------|------------------------------|
| Markdown under a content root | **HTML** site (default) |
| Closed frontmatter | **JSON IR** (`--out`) |
| Optional theme layouts + assets | **RAG** pack (`--rag`) |
| Same validated graph | **Context Bundle** (`--context`) |

There is no Node SSG, no React runtime, and no subprocess Markdown renderer.
Markdown is rendered in-process with ApexMarkdown Unified.

Teaching rhythm (narrative only): **Load → Roll → Ignite → Reset**.

---

## Non-negotiables (read before bulk conversion)

1. **Closed frontmatter** — only `id`, `title`, `parent`, `status`, `tags`.
2. **Parent key is `parent` only** — `parentEntry` / `parent_entry` fail as
   unknown keys.
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
   `<Aside …>` outside fences is a real component.
8. **Themes** — trusted static HTML layouts + copied `assets/`; no CDN fetch
   in the compile path.
9. **UTF-8 without BOM** — BOM rejects the file.

Normative detail lives under [`docs/contracts/`](contracts/) when you need
machine rules; this guide stays author-facing.

---

## Recommended migration sequence

### 1. Inventory the old site

Export a list of:

- Every Markdown path
- Nav / sidebar hierarchy
- Shared snippets / partials
- Internal link style (`[x](../a.md)`, `@site`, `ref`, wiki, etc.)
- Theme assets (CSS, fonts, images)
- Frontmatter keys in use

### 2. Choose the content root shape

```text
your-site/
  content/           # pages + includes/
  theme/             # layouts/, footer.html, assets/
```

For experiments against this repository, use the fixture paths instead of
replacing root `content/` (root `content/` remains product dogfood).

### 3. Convert frontmatter

| Keep / map | Drop or rewrite |
|------------|-----------------|
| `title` → `title` | Nested YAML objects |
| Section parent → `parent: <trunk-id>` | `parentEntry`, `parent_entry` |
| Tags list → `tags: [a, b]` | Arrays of maps, aliases |
| Draft flag → `status: draft` | Unknown keys (`sidebar_position`, `weight`, …) |

Minimal satellite:

```markdown
---
title: Getting started
parent: guides
status: published
tags: [guides]
---
```

Minimal trunk (section landing):

```markdown
---
title: Guides
status: published
tags: [guides]
---
```

### 4. Build the Trunk / Satellite forest

1. Create a **Trunk** landing page per top-level section (`guides.md`, …).
2. Set each child page `parent:` to that section’s **entity id**.
3. Flatten deeper sidebar levels — graph depth is one parent hop only.
4. Keep true orphans as intentional Trunks (or attach them).

### 5. Replace partials and callouts

| Old mechanism | Boris |
|---------------|-------|
| Snippets / partials | `{{include includes/….md}}` |
| Admonition plugins | `<Aside kind="tip">…</Aside>` |
| MDX components | Static Markdown / Aside / include |

### 6. Replace internal links

| Old | Boris |
|-----|-------|
| `[Text](../guides/foo.md)` | `[[guides/foo\|Text]]` |
| Heading anchors guessed from another SSG | Build once; copy rendered `id` |
| Case-insensitive paths | Exact entity id bytes |

### 7. Port the theme

```text
theme/
  layouts/main.html
  footer.html          # optional
  assets/css/….css
  assets/img/….svg
```

Required layout marker: `{{content}}` exactly once.

Useful optional markers: `{{title}}`, `{{nav}}`, `{{breadcrumb}}`, `{{toc}}`,
`{{metadata}}`, `{{footer}}`, and `{{asset-url assets/…}}` for page-relative
asset URLs.

### 8. Compile, fix, repeat

Use exit codes: **0** ok · **1** content · **2** usage · **3** I/O.

---

## Exact commands (fixture)

From the Boris repository root after `zig build`:

### HTML site

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --theme fixtures/migration-site/theme \
  --html-dir test-output/migration-dist \
  --quiet
```

**Expected**

| Check | Result |
|-------|--------|
| Exit code | `0` |
| Home page | `test-output/migration-dist/index.html` |
| Deep page | `test-output/migration-dist/guides/deep/nested/path/note.html` |
| Mixed-case path | `test-output/migration-dist/reference/HTTP-status.html` |
| Case-sensitive id | `test-output/migration-dist/special/CaseDemo.html` |
| Unicode body demo | `test-output/migration-dist/special/cafe-notes.html` |
| Theme CSS | `test-output/migration-dist/assets/css/site.css` |
| Theme image | `test-output/migration-dist/assets/img/mark.svg` |
| Page count | ≈32 HTML files under the html-dir |
| Includes as pages | **None** — `includes/` not emitted |

Spot-check in HTML source:

- No raw `[[entity]]` left in body prose (wiki rewritten).
- `href` to CSS is page-relative (`assets/…` or `../assets/…`, etc.).
- Sidebar contains Trunk forest entries.

### JSON IR

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --out test-output/migration-ir \
  --quiet
```

**Expected:** exit `0` and these files:

```text
test-output/migration-ir/manifest.json
test-output/migration-ir/graph.json
test-output/migration-ir/build-report.json
```

### RAG pack (optional)

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --rag-dir test-output/migration-rag \
  --quiet
```

**Expected:** exit `0`; corpus files under the rag-dir. Do not commit.

### AI Context Bundle (optional)

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --context-dir test-output/migration-context \
  --quiet
```

**Expected:** exit `0` and at least:

```text
test-output/migration-context/bundle.md
test-output/migration-context/manifest.json
test-output/migration-context/graph.json
test-output/migration-context/pages/
```

Upload `bundle.md` (or the directory) as **grounded context** for an LLM — not
as a substitute for source control or the HTML site. Contract:
[context-bundle.md](contracts/context-bundle.md).

### Incremental + jobs

```bash
./zig-out/bin/boris \
  --input fixtures/migration-site/content \
  --theme fixtures/migration-site/theme \
  --html-dir test-output/migration-dist \
  --jobs 4 \
  --incremental \
  --quiet
```

**Expected:** exit `0`; may create target cache under
`test-output/migration-dist/.boris-cache/` (untracked / local only).

### One tree, several page shapes

Many migrations have a home page, section landings, and an archive or reference
area that should not share the same chrome. After adding those layouts to your
theme, keep the content graph in one tree and select the exceptional HTML
layouts at build time rather than introducing a second content dialect:

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

Use `id:<entity-id>` for one known page, `glob:<segment-pattern>` for a stable
path family, and `role:trunk|satellite` for graph role. Rules are HTML-only;
they intentionally do not change frontmatter, IR, RAG, or Context Bundle
output.

### Migration follow-up checklist

After the first clean HTML build:

- [ ] Add `--layout-rule` only where the old site has genuinely distinct page
  shapes (home, archive, reference), not for ordinary visual tweaks.
- [ ] Run `boris check --format json --report .boris/check.json` and review
  unreferenced-page findings before declaring the tree complete.
- [ ] Run `boris impact <entity-id>` before a broad rename to see the validated
  dependent set.
- [ ] Export `--context-dir test-output/migration-context` when an LLM or
  reviewer needs the validated hierarchy and source-relative provenance; use
  the bundle as context, not as a replacement for source control.
- [ ] Keep the full build and a deep-page asset check in the migration handoff.

### Your own tree

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

### After

- [ ] Full HTML build (no `--incremental`) → exit `0`.
- [ ] Grep for retired ids → zero hits in active content.
- [ ] Open a deep page; confirm CSS/img load.
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
  referenced by content. Boris manages static theme bytes only under
  `theme/assets/`; move shared output assets there, update links deliberately,
  and check a deep generated page for working URLs. See
  [templating and themes](contracts/templating-and-themes.md).
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
| Shortcodes | Include / Aside / Markdown |
| `static/` | Theme `assets/` |
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
| MDX components | Strip; static only |
| `@site` links | Wiki entity ids |
| `static/` | Theme assets |

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
| `zig-out/`, `.zig-cache/` | Build outputs |

Repository `.gitignore` already covers common product output roots such as
`dist/`, `rag/`, and `test-output/`. Write experimental HTML/IR/RAG under
`test-output/…` (or another ignored path **inside** the workspace — Boris
rejects outputs that escape the workspace root).

---

## Fixture coverage matrix

| Concern | Where in the fixture |
|---------|----------------------|
| 20–40 pages | ~32 pages under `content/` |
| Trunk / Satellite | Section landings + children |
| Includes | `content/includes/*` + live `{{include}}` |
| Wiki links | Throughout guides/reference |
| Heading fragments | `guides/heading-fragments.md` |
| Layouts + theme assets | `theme/layouts`, `assets/css`, `assets/img` |
| Unicode | Titles, body, headings; ASCII path `special/cafe-notes.md` (wiki-linkable) |
| Punctuation in headings | `guides/heading-fragments.md` |
| Deep paths | `guides/deep/nested/path/note.md` |
| Case-sensitive IDs | `special/CaseDemo.md`, `reference/HTTP-status.md` |
| Rename checklist | This doc + `cookbook/rename-pages.md` |
| Exact commands | This doc + `reference/cli.md` |

---

## Verification while developing Boris itself

When you only touch content, layouts, assets, and docs (as with this guide):

```bash
zig build test
# optional broader gate when convenient:
./scripts/release-gate.sh
```

The migration fixture is **not** required by the release gate; it is an
authoring and conversion aid.

---

## Related reading

| Doc | Role |
|-----|------|
| [`fixtures/migration-site/README.md`](../fixtures/migration-site/README.md) | Fixture how-to |
| [`tools/migration-lab/README.md`](../tools/migration-lab/README.md) | Standalone labs (Astro / WordPress WXR / Instagram / Obsidian / Notion) |
| [`tools/migration-lab/fixtures/unit-wxr/`](../tools/migration-lab/fixtures/unit-wxr/) | WordPress unit-matrix fixture (preserve/report policy) |
| [`README.md`](../README.md) | Product front door + CLI |
| [`docs/STATUS.md`](STATUS.md) | Current phase |
| [`docs/contracts/frontmatter.md`](contracts/frontmatter.md) | Normative FM grammar |
| [`docs/contracts/includes-and-wiki-links.md`](contracts/includes-and-wiki-links.md) | Includes + wiki |
| [`docs/contracts/heading-ids.md`](contracts/heading-ids.md) | Fragment ids |
| [`docs/contracts/templating-and-themes.md`](contracts/templating-and-themes.md) | Themes |
| [`docs/contracts/parent-relationships.md`](contracts/parent-relationships.md) | Graph parents |
