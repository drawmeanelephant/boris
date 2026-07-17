# boris-migration-lab

Standalone **migration laboratory** for bringing existing sites into Boris.

| Mode | Input | Output |
|------|--------|--------|
| **astro** | Astro project/export tree | Deterministic archaeology `report.json` + `REPORT.md` |
| **wordpress** | WordPress WXR/XML + optional local media | Boris-ready Markdown under `content/` + review reports |
| **instagram** | Unpacked Instagram data-download (Takeout) | Boris Markdown + generated theme assets + reports |
| **obsidian** | Local Obsidian vault directory | Boris Markdown + attachments inventory + review reports |
| **notion** | Official Notion “Markdown & CSV” export (unpacked) | Boris Markdown + media inventory + review reports |
| **filed** | Filed.fyi Astro source root | Bounded changelog/releases Boris tree + provenance/review reports |
| **starlight** | Starlight/Astro docs root (locale-dir or root-locale) | Boris candidate `content/` + route/link/nav/asset/selection/boundary manifests + compile report |
| **asset-filename** | Content tree with sibling `{stem}.assets/` files | Sanitized Boris-safe asset names + rewritten Markdown refs + manifests |
| **theme-archaeology** | Astro/Starlight-shaped theme or project root | Deterministic adaptation ledger + boundary report (read-only) |

All modes are **read-only on inputs**: originals are never rewritten. There is
**no network access**, no zip extraction, no scraping, and **no product compiler
coupling**. All code and fixtures live under `tools/migration-lab/`.

| | |
|--|--|
| Source | `tools/migration-lab/` |
| Binary | `zig-out/bin/boris-migration-lab` (local package install) |
| Build | `zig build` from this directory |
| Tests | `zig build test` from this directory; targeted aggregate gate |
| Astro format id | `boris-astro-migration-lab` |
| WordPress format id | `boris-wordpress-migration-lab` |
| Instagram format id | `boris-instagram-migration-lab` |
| Obsidian format id | `boris-obsidian-migration-lab` |
| Notion format id | `boris-notion-migration-lab` |
| Filed format id | `boris-filed-fyi-migration-lab` |
| Starlight format id | `boris-starlight-migration-lab` |
| Asset-filename format id | `boris-asset-filename-lab` |
| Theme-archaeology format id | `boris-theme-archaeology-lab` |
| Schema | Astro/Instagram/Obsidian/Notion/Filed/Starlight/Asset-filename/Theme-archaeology `1`; WordPress **`3`** |

Companion author guide: [`docs/MIGRATION.md`](../../docs/MIGRATION.md).

---

## Quick start

From **`tools/migration-lab/`** (Zig **0.16+**):

```bash
zig build
zig build test

# Astro archaeology
zig build run -- --mode=astro --root=./fixtures/mini-astro --out=./.migration-report

# WordPress WXR → Boris Markdown + reports
zig build run -- --mode=wordpress \
  --wxr=./fixtures/mini-wxr/export.xml \
  --media=./fixtures/mini-wxr/media \
  --out=./.wp-report

# Instagram Takeout → Boris Markdown + theme assets + reports
zig build run -- --mode=instagram \
  --dump=./fixtures/mini-instagram \
  --out=./.ig-report

# Obsidian vault → Boris Markdown + attachments + reports
zig build run -- --mode=obsidian \
  --vault=./fixtures/mini-obsidian \
  --out=./.obs-report

# Notion Markdown & CSV export → Boris Markdown + media + reports
zig build run -- --mode=notion \
  --export=./fixtures/mini-notion \
  --out=./.notion-report

# Filed.fyi first reversible slice
zig build run -- --mode=filed \
  --filed-root=/path/to/filed-fyi \
  --out=/tmp/filed-boris-content

# Starlight dogfood — synthetic ~60-page fixture (committed)
zig build run -- --mode=starlight \
  --root=./fixtures/dogfood-starlight \
  --out=./.dogfood-sl-out \
  --locale=en \
  --max-pages=80

# Optional real-site smoke — withastro/starlight docs (root-locale; clone to /tmp only)
zig build run -- --mode=starlight \
  --root=/tmp/starlight/docs \
  --out=/tmp/starlight-boris-out \
  --locale=en \
  --max-pages=50

# Content-local asset filename compatibility (spaces / Unicode / %20 → Boris-safe)
zig build run -- --mode=asset-filename \
  --root=./fixtures/hostile-asset-filenames \
  --out=./.asset-filename-out

# Theme archaeology (read-only inventory → adaptation ledger + boundary)
zig build run -- --mode=theme-archaeology \
  --root=./fixtures/mini-theme-astro \
  --out=./.theme-arch-out

# Hostile theme signals (runtime scripts, remote CSS, duplicates, traversal)
zig build run -- --mode=theme-archaeology \
  --root=./fixtures/hostile-theme-astro \
  --out=./.theme-arch-hostile-out
```

From the **repository root**, use this targeted aggregate gate after changing
`tools/migration-lab/`. Root `zig build test` deliberately covers only the
product compiler and does not include this standalone laboratory:

```bash
zig build --build-file tools/migration-lab/build.zig
zig build --build-file tools/migration-lab/build.zig test
zig build --build-file tools/migration-lab/build.zig run -- \
  --wxr=tools/migration-lab/fixtures/mini-wxr/export.xml \
  --media=tools/migration-lab/fixtures/mini-wxr/media \
  --out=/tmp/wp-mig-report
zig build --build-file tools/migration-lab/build.zig run -- \
  --mode=instagram \
  --dump=tools/migration-lab/fixtures/mini-instagram \
  --out=/tmp/ig-mig-report
zig build --build-file tools/migration-lab/build.zig run -- \
  --mode=obsidian \
  --vault=tools/migration-lab/fixtures/mini-obsidian \
  --out=/tmp/obs-mig-report
zig build --build-file tools/migration-lab/build.zig run -- \
  --mode=notion \
  --export=tools/migration-lab/fixtures/mini-notion \
  --out=/tmp/notion-mig-report
```

### Flags

| Flag | Default | Meaning |
|------|---------|---------|
| `-h`, `--help` | | Print usage; exit 0 |
| `-q`, `--quiet` | off | Suppress progress lines |
| `--mode=MODE` | `astro` | `astro`, `wordpress` (`wp` / `wxr`), `instagram` (`ig` / `takeout`), `obsidian` (`obs` / `vault`), `notion` (`md-csv` / `notion-export`), `filed` (`filed-fyi`), `starlight` (`sl` / `evcc`), `asset-filename` (`assets` / `asset-compat` / `filename-compat`), or `theme-archaeology` (`theme` / `theme-arch` / `theme-inventory`) |
| `--out=DIR` | `migration-report` | Output directory (**must differ from inputs**) |
| `--root=DIR` | `.` | Astro archaeology root, Starlight project root, asset-filename content tree, **or** theme-archaeology scan root |
| `--wxr=FILE` | | WordPress WXR/XML path (implies `--mode=wordpress`) |
| `--media=DIR` | | Optional offline local media/uploads tree (WordPress); never modified; no network |
| `--dump=DIR` | | Unpacked Instagram data-download root (implies `--mode=instagram`) |
| `--vault=DIR` | | Obsidian vault root (implies `--mode=obsidian`) |
| `--export=DIR` | | Unpacked Notion Markdown & CSV export root (implies `--mode=notion`) |
| `--filed-root=DIR` | | Filed.fyi Astro source root (implies `--mode=filed`) |
| `--locale=en` | `en` | Starlight discovery key (**en only**). Uses `src/content/docs/en/` when present; else root-locale files under `src/content/docs/` |
| `--max-pages=N` | `40` | Starlight converted-page cap (dogfood often 40–80) |
| `--boris=PATH` | auto | Optional product `boris` binary for Starlight compile verification |

Exit codes: **0** success, **2** usage, **3** I/O error.

---

## Safety rules

1. **Preserve originals** — only writes under `--out`.
2. **No network** — no fetches, no package installs, no oEmbed expansion.
3. **No destructive source ops** — no delete/rename of WXR, media, vault, or scan-root files.
4. **No product coupling** — does not import `src/` compiler modules; not in root `zig build test`.
5. **Deterministic** — sorted ids/paths; fixed field order; no host timestamps in report bodies.
6. **Never silently discard** — unsupported items are preserved under `content/_preserved/` (WordPress) or left raw in-place (Obsidian links) and listed in the report.
7. **Instagram** — no zip extraction; dump must already be unpacked. DMs, logins,
   followers, and ads trees are not read.
8. **Obsidian** — never ingest or commit a private vault; use a local path only.
   `.obsidian/`, `.git/`, `node_modules/`, and generated/output dirs are skipped.
9. **Notion** — official **Markdown & CSV** export only (already unpacked). No
   Notion API, OAuth, remote fetch, or private workspace data in the repo.
   Hidden/tooling dirs (`.git/`, `node_modules/`, `dist/`, …) are skipped.
10. **Asset-filename** — never relaxes Boris core path grammar; only rewrites
    under `--out`. Symlinks and destination collisions are rejected (no silent
    overwrite). No remote asset fetch and no source-site JavaScript execution.
11. **Theme-archaeology** — inventory only (writes under `--out`). Never
    executes JS/MDX, never fetches remotes, never follows embedded directives,
    never mutates the source theme. Ambiguous mappings are **review**, never
    guesses.

---

## Theme archaeology (Astro / Starlight-shaped)

Read-only inventory of theme-shaped trees so a future converter (and humans)
can see what can be preserved versus what needs design work. This mode does
**not** generate a Boris theme; it emits a deterministic **adaptation ledger**
and a **boundary report**.

```bash
zig build run -- --mode=theme-archaeology \
  --root=./fixtures/mini-theme-astro \
  --out=/tmp/theme-arch-out
```

### What is inventoried

| Category | Typical sources |
|----------|-----------------|
| Layouts / templates | `src/layouts/**`, page `.astro` shells |
| CSS + imports | `*.css`, `@import`, `url(...)`, `<link rel=stylesheet>` |
| Fonts / images | `public/`, `src/assets/`, font/image extensions |
| Navigation / sidebar | text-scan of `astro.config.*` (`sidebar`, `slug`, `autogenerate`) |
| Components + MDX tags | `src/components/**`, PascalCase tags in MDX/Astro |
| Scripts / analytics / runtime | `<script>`, `client:*`, `import.meta.env`, analytics hosts |
| Licenses / provenance | `LICENSE` / `NOTICE` / `package.json` `license` field |

### Adaptation ledger fields

Each row in `adaptation_ledger.json` has:

| Field | Meaning |
|-------|---------|
| `source_path` | Scan-root-relative path (`/` separators) |
| `category` | `layout`, `css`, `font`, `image`, `navigation`, `component`, `mdx_tag`, `script`, `analytics`, … |
| `sha256` | File content hash when applicable; `null` for extracted evidence rows |
| `proposed_boris_equivalent` | Closed suggestion only (theme path, native Aside/Details, or `(none …)`) |
| `decision` | `preserve` · `adapt` · `review` · `drop` |
| `reason` / `evidence` | Deterministic classification code + line/path evidence |
| `unsupported_runtime` | `true` when the signal depends on JS/MDX/remote/env runtime |

### Outputs

| Output | Role |
|--------|------|
| `adaptation_ledger.json` | Full sorted ledger |
| `report.json` / `REPORT.md` | Counts + policy + human summary |
| `BOUNDARY.md` | What a future converter could safely generate vs human design work |

### Decision policy (closed)

| Decision | When |
|----------|------|
| **preserve** | Static CSS/fonts/images/license bytes transferable without reinterpretation |
| **adapt** | Closed mapping exists (layout → `theme/layouts/*.html` slots; Aside/Details tags) |
| **review** | Ambiguous or multi-valid (sidebar, unknown components, analytics placement) |
| **drop** | Out of scope or refused (remote fetch, traversal, islands, inline runtime scripts) |

Hostile fixture: [`fixtures/hostile-theme-astro/`](fixtures/hostile-theme-astro/)
(runtime scripts, remote CSS, duplicate assets, unsupported components, path
traversal, embedded directives). Friendly fixture:
[`fixtures/mini-theme-astro/`](fixtures/mini-theme-astro/).

**Why this stays in the lab:** theme conversion is a design problem (nav graph,
component vocabulary, trusted layout HTML). The product compiler copies
declared theme assets and slots only; it must not invent layout semantics from
Astro/MDX source.

---

## Asset filename compatibility (content-local)

Boris core content-local assets accept only ASCII path segments
`[A-Za-z0-9._-]+` under sibling `{page-stem}.assets/` trees (normative:
[`docs/contracts/content-local-assets.md`](../../docs/contracts/content-local-assets.md)).
Astro/Starlight archives frequently use **spaces**, **Unicode**, or **literal
`%20`-style** names that the product compiler rejects by design.

`--mode=asset-filename` is the lab adapter for that gap:

1. Discover Markdown pages and sibling `{stem}.assets/**` trees under `--root`
   (or `--root/content` when present).
2. Detect within-tree paths Boris would reject; leave already-safe names
   unchanged.
3. Deterministically sanitize unsafe segments (URL-decode `%XX` first; spaces /
   non-ASCII / other punctuation → `-`; preserve nested directories).
4. Copy accepted assets into `--out/content/` under sanitized destinations.
5. Rewrite Markdown image and link destinations (fence-aware) to the sanitized
   paths, including `%20` reference forms of original names.
6. Record every asset with **original path**, **destination path**, **action**,
   **reason**, and **SHA-256** in `asset_filename_manifest.json`.
7. Record Markdown rewrites in `rewrite_manifest.json`.
8. Reject **destination collisions** and **case collisions** (ASCII
   case-fold); first source path wins; never silent overwrite.
9. Reject **symlinks** and **traversal** within-tree forms; leave hostile
   `../` Markdown destinations unre-written for human review.
10. Keep the source tree byte-identical; repeated runs are byte-identical.

```bash
zig build run -- --mode=asset-filename \
  --root=./fixtures/hostile-asset-filenames \
  --out=/tmp/asset-filename-out
```

| Output | Role |
|--------|------|
| `content/**` | Sanitized pages + `.assets/` trees |
| `asset_filename_manifest.json` | Source → dest inventory (reason + SHA-256) |
| `rewrite_manifest.json` | Markdown destination rewrites |
| `report.json` / `REPORT.md` | Counts + policy + human summary |

Hostile fixture: [`fixtures/hostile-asset-filenames/`](fixtures/hostile-asset-filenames/)
(spaces, Unicode, `%20` names, nested dirs, case collision, sanitized-name
collision, traversal refs, symlink).

**Why this stays in the lab (not Boris core):** product path validation is a
deliberate fail-closed safety boundary for publish correctness, incremental
cleanup, and portable URLs. Migration archives are dirty by nature; sanitizing
them is a one-way import concern with provenance, not a reason to widen the
runtime contract.

---

## Filed.fyi first slice

This developer-only proof accepts a **read-only clone or checkout** of Filed.fyi
and only reads these observed Astro collection directories:

```text
src/content/docs/changelog/   # exactly one .md or .mdx record
src/content/docs/releases/    # exactly three .md or .mdx records
```

Run it from this directory with an output directory outside the Filed.fyi
checkout:

```bash
zig build run -- --mode=filed \
  --filed-root=/absolute/path/to/filed-fyi \
  --out=/tmp/filed-boris-content
```

It creates `content/changelog/index.md` and `content/releases/index.md` as
Trunks, plus one changelog and three release Satellites with closed Boris `id`, `title`,
`parent`, `status`, and `tags` frontmatter. `provenance_manifest.json` retains
every raw source frontmatter block and output mapping. `report.json` and
`REPORT.md` explicitly list each non-`title` source frontmatter field as
unmapped; values are retained verbatim but never interpreted or normalized. The run fails if the source
does not have the expected one-plus-three record cardinality.

This is deliberately not a general Astro/MDX migration: no arbitrary YAML,
MDX components, Starlight navigation, date joins, or live synchronization.
Review flagged pages before passing the generated tree to Boris.

Filed bodies are untrusted archival data. Clearly delimited `agent`,
`directive`, `instruction`, or `prompt` fences/tags are stripped mechanically
without reproducing their contents. Reports retain only source path, source line,
neutral category, and `stripped: true`.

Synthetic redistributable coverage lives in
[`fixtures/mini-filed/`](fixtures/mini-filed/).

A bounded real-site adoption pass (Filed.fyi changelog/releases slice against
current `main`, including product HTML/IR/RAG evidence and remediation cards)
is recorded in
[`docs/dogfood/filed-fyi-adoption-pass.md`](../../docs/dogfood/filed-fyi-adoption-pass.md).

## Starlight read-only dogfood (locale-dir + root-locale)

Developer-only **read-only dogfood** preflight + bounded converter for a
Starlight content tree. Content-root discovery supports both shapes (**no i18n /
translation linking**). This is **not** a universal converter and does **not**
invent semantic transformations.

| Shape | Layout | Fixture |
|-------|--------|---------|
| **locale_dir** | `src/content/docs/{locale}/…` | [`fixtures/mini-starlight/`](fixtures/mini-starlight/), [`fixtures/hostile-starlight/`](fixtures/hostile-starlight/) |
| **root_locale** | default language under `src/content/docs/` | [`fixtures/mini-starlight-root/`](fixtures/mini-starlight-root/), [`fixtures/dogfood-starlight/`](fixtures/dogfood-starlight/) (~67 pages) |

When `--locale=en` and `src/content/docs/en/` exists with markdown, that directory
is used. Otherwise the lab uses the docs root and skips sibling first-level dirs
that look like locale codes (`de`, `zh-cn`, …). Routes are `/en/…` for locale-dir
and `/…` for root-locale.

### What it does

1. **Discovers** the content root (locale-dir vs root-locale) and inventories
   markdown, route-style and relative links, frontmatter keys (line-oriented, not
   full YAML), MDX imports/components, sidebar evidence from `astro.config.*`
   (text scan only), and local/public assets.
2. **Selects candidates deterministically**: lexicographic path order, drop
   underscore partials (`_foo.mdx`), apply `--max-pages` (default 40). **No**
   preferred-section allowlist.
3. **Detects entity collisions** (same route/entity from multiple sources): first
   source path wins; others get deterministic `-2`, `-3`, … suffixes; all rows are
   listed for human review (no silent overwrite).
4. **Emits** a Boris candidate tree under `--out/content/` with closed frontmatter
   only: `id`, `title`, `parent`, `status`, `tags`.
5. **Rewrites** internal markdown routes/relative links to `[[entity-id]]` **only**
   when the target exists in the converted entity map; otherwise writes an explicit
   `link_review.json` row (unresolved routes, fragments, attribute links, assets,
   external URLs).
6. **Migrates proven Markdown images** into Boris page-sibling `{stem}.assets/`
   trees under `--out` when the source file resolves relative to the document
   directory or under `public/` (site-absolute `/…`). Missing, escape, and
   non–Boris-safe paths are left unchanged with explicit review reasons — never
   invented. Query strings on image URLs are dropped (same as link targets);
   `#fragments` are reattached when present.
7. **Sidecar manifests** (deterministic; repeated runs byte-identical):

   | Manifest | Contents |
   |----------|----------|
   | `selection_manifest.json` | Selected source files + exclusion reasons |
   | `route_map.json` | Route / entity / output mapping |
   | `link_review.json` | Internal links, unresolved, external, assets |
   | `heading_fragments.json` | Fragment inventory (headings **not** verified) |
   | `assets_manifest.json` | Inventory + migrated page assets (exists + SHA-256 when proven) |
   | `nav_flatten.json` | Sidebar/nav evidence (text scan only) |
   | `unsupported_manifest.json` | Unmapped FM + MDX + entity collisions |
   | `boundary_manifest.json` | **preserved** / **stripped** / **manual_review** |
   | `provenance_manifest.json` | Raw frontmatter + source provenance |
   | `compile_report.json` | Optional Boris compile attempt |
   | `report.json` / `REPORT.md` | Machine + human summaries |

8. **Preserves source read-only** and proves immutability + repeated-run byte
   determinism in fixture tests (including dogfood-scale and hostile fixtures).
9. **Attempts a Boris compile** of the candidate (when `boris` +
   `layouts/main.html` are findable) and records the result in `compile_report.json`.
10. **Does not** couple product `boris` into the lab binary; image copies stay
    under `--out/content/**` only.

### Boundary classes

| Class | Meaning |
|-------|---------|
| **preserved** | Body text or asset inventory retained without invented semantics |
| **stripped** | Untrusted agent/directive/instruction/prompt fences removed; payload never replayed |
| **manual_review** | Human migration work still required (MDX, FM, links, fragments, collisions, assets, deep paths, …) |

### Supported / unsupported matrix

| Area | Status | Notes |
|------|--------|-------|
| Content root `docs/{locale}/` | **Supported** | Locale-directory shape |
| Content root `docs/` (default locale) | **Supported** | Root-locale shape; sibling locale dirs skipped |
| Frontmatter `title` | **Supported** | Mapped into Boris `title` |
| Frontmatter `id` / `parent` / `status` / `tags` | **Emitted by converter** | Source values of those keys (if any) are listed unmapped; converter owns the closed grammar |
| Other YAML keys (`sidebar`, nested maps, sequences, …) | **Unsupported** | Retained raw in provenance; never interpreted |
| Full YAML / JS config evaluation | **Unsupported** | `astro.config.*` text-scanned for sidebar evidence only |
| Markdown body | **Supported** | Passed through after MDX import strip + untrusted-fence strip |
| MDX imports / components | **Unsupported** | Inventoried; tags neutralized; not executed |
| Internal markdown route / relative links | **Conditional** | Wiki rewrite only when target entity is in the converted entity map |
| Fragments (`#heading`) | **Review** | `heading_fragments.json`; heading not verified |
| Attribute `href` / `to` routes | **Review only** | Never auto-rewritten |
| External links | **Left as-is** | Inventoried as external |
| Local / public Markdown images | **Conditional** | Proven relative/public images → page `{stem}.assets/` + rewrite; missing/escape/invalid → review (never invented). Query strings dropped; fragments preserved. Non-image asset links remain inventory-only. |
| Duplicate / ambiguous routes | **Disambiguated + reviewed** | First path wins; others `-2`… |
| Sidebar / `autogenerate` | **Flattened** | One-level forest: section Trunk + Satellite children |
| Translation linking / i18n | **Unsupported** | Content-root discovery only; no locale semantics |
| Live sync / Node / Astro / Starlight runtime | **Unsupported** | No package install, no MDX runtime |
| Deep multi-hop parents | **Unsupported** | Matches Boris one-level forest; no new graph behavior |
| Embedded agent/directive/prompt fences | **Stripped** | Payload never replayed; report lists path/line/category |
| Universal conversion | **Not claimed** | Mechanical inventory + proven rewrites only |

### Fixtures

| Fixture | Role |
|---------|------|
| [`dogfood-starlight/`](fixtures/dogfood-starlight/) | ~67-page root-locale dogfood (nested docs/blog, assets, FM variants, MDX, sidebar, partials) |
| [`image-path-starlight/`](fixtures/image-path-starlight/) | **F-L1** image resolve matrix: relative sibling, nested, missing, escape, already-correct `{stem}.assets/`, public absolute |
| [`hostile-starlight/`](fixtures/hostile-starlight/) | Ambiguous routes, deep paths, unicode, unsupported MDX/FM, instruction fences |
| [`mini-starlight/`](fixtures/mini-starlight/) | Compact locale-dir proof |
| [`mini-starlight-root/`](fixtures/mini-starlight-root/) | Compact root-locale proof |

### Real-site smoke (do not commit upstream)

```bash
# Clone outside the repo — never commit upstream content or run its Node scripts.
# Pin a commit for reproducibility.
git clone https://github.com/withastro/starlight.git /tmp/starlight
cd /tmp/starlight && git checkout 02fea60ecf5b07449dc6620cb85bd746944b79aa

# Project root for the docs package is /tmp/starlight/docs (root-locale English).
cd /path/to/boris/tools/migration-lab
zig build run -- --mode=starlight \
  --root=/tmp/starlight/docs \
  --out=/tmp/starlight-boris-out \
  --locale=en \
  --max-pages=50

# Inspect boundary + manifests
less /tmp/starlight-boris-out/REPORT.md
less /tmp/starlight-boris-out/boundary_manifest.json
# Expect content_shape=root_locale.
```

Source text is **untrusted data**: the converter never follows embedded
directives or prompts. Prefer the committed
[`fixtures/dogfood-starlight/`](fixtures/dogfood-starlight/) tree for CI and
local dogfood; keep upstream clones on `/tmp` only.

## Notion mode

### Inputs

- An **unpacked** official Notion export directory (**Markdown & CSV**).
- Expects page files named like `Title <32-hex-id>.md` with nested sibling folders
  of the same stem for subpages, local attachments beside pages, and `.csv` for
  full-page databases.
- Does **not** call the Notion API, perform OAuth, download remote assets, or
  extract zip files (export must already be unpacked).

### Outputs under `--out`

```text
content/
  <entity-id>.md           # one file per discovered page (ids stripped from paths)
media/
  ...                      # copied local attachments (bytes unchanged)
report.json
REPORT.md
media_manifest.json        # deterministic source→output inventory
```

Each page uses **closed Boris frontmatter** where possible (`title`, optional
`parent` / `status` / `tags`), preserves compatible authored frontmatter, drops
unknown keys into the review queue, and appends a
`boris-migration-provenance` comment (export path, entity id, Notion page id).

| Class | Typical cause |
|-------|----------------|
| `exact` | Plain page body with no rewrites needed |
| `transformed` | Parent inferred from folders; local links/media rewritten |
| `unsupported` | Relation/rollup, synced blocks, embeds, unsupported block markers |
| `human_review` | Ambiguous/unresolved links, CSV databases, deep hierarchy, unknown FM |

| Flagged (never silent drop) | Handling |
|----------------------------|----------|
| Database CSV views | `unsupported_items` + human review |
| Relation / rollup markers | hazard + human review; body retained raw |
| Synced blocks / embeds / unsupported blocks | hazard + human review; retained raw |
| Ambiguous page/media targets | link left raw + human review |
| Unresolved local links | link left raw + human review |
| Nesting deeper than one hop | `deep_hierarchy` review (Boris graph is one parent hop) |

Synthetic fixture: [`fixtures/mini-notion/`](fixtures/mini-notion/).

```bash
zig build run -- --mode=notion \
  --export=./fixtures/mini-notion \
  --out=./.notion-report
```

---

## Obsidian mode

### Inputs

- A local **Obsidian vault directory** (folder of Markdown notes + attachments).
- Does **not** read or depend on Obsidian app UI, sync, or plugins at runtime.
- Skips `.obsidian/`, `.git/`, `node_modules/`, `dist/`, `.output/`, and similar
  generated directories.

### Outputs under `--out`

```text
content/
  <entity-id>.md           # one file per vault note (path-mapped id)
assets/
  <vault-relative-path>    # inventoried local attachments (copied)
report.json
REPORT.md
attachments_manifest.json
```

### What phase-1 does

| Step | Behavior |
|------|----------|
| Discover | Deterministic walk of vault Markdown (`.md` only as pages) |
| Frontmatter | Keep closed Boris keys (`id`, `title`, `parent`, `status`, `tags`); drop/report unknown keys |
| Entity ids | Vault-relative path → wiki-safe id (spaces → `-`; case preserved) |
| Wiki links | Rewrite `[[Note]]` / `[[Note\|alias]]` only when the target resolves **unambiguously** |
| Embeds | Rewrite unambiguous `![[asset]]` to Markdown image/link; flatten unambiguous note embeds to `[[entity-id]]` |
| Attachments | Copy/inventory into `assets/` + deterministic `attachments_manifest.json` |
| Review report | Unresolved, ambiguous, heading/block refs, Canvas, Dataview, plugin syntax, unsupported embeds |

### What phase-1 does **not** do

- Dataview / DataviewJS evaluation or live queries
- Canvas conversion
- Plugin behavior (Tasks, Templater, etc.)
- Heading or block-reference rewrite (`[[Note#Heading]]`, `[[Note#^block]]`)
- Silent drop of unresolved/ambiguous links (left raw + reported)
- Product compiler / contract changes

### Link resolution rules

1. Exact vault path / stem (`Notes/Beta`, `Notes/Beta.md`)
2. Exact mapped entity id (`Notes/Beta`)
3. Sanitized target equals entity id (`Q1 Plan` → `Q1-Plan` when unique)
4. Unique **path-suffix** on vault stem (`Concept Board/X` → `Vault/Concept Board/X`)
5. Unique path-suffix on sanitized entity id
6. Unique basename (`Beta` → single note named `Beta.md`)
7. Unique last-segment basename when the target contains `/`
8. Multiple matches → **ambiguous** (raw retained)
9. No match → **unresolved** (raw retained)
10. Templater / `${…}` / `<%…%>` wiki targets → **plugin_template** (raw + plugin hazard; not unresolved)
11. Inside fenced code → left unchanged

Entity ids that collide after sanitization (e.g. `Hello World.md` vs
`Hello-World.md`) are **disambiguated** deterministically (`…-2`, `…-3`, …) so
output paths never clobber; collisions are listed under `unsupported_items`.

### Fixture

[`fixtures/mini-obsidian/`](fixtures/mini-obsidian/) — public synthetic vault
(collisions, path-suffix links, Templater placeholders, spaces, embeds,
Dataview, Canvas, ignored `.obsidian` / `node_modules`). Coverage notes:
[`fixtures/mini-obsidian-README.md`](fixtures/mini-obsidian-README.md).

### Compile generated content with product Boris

```bash
# after a successful migration-lab run
./zig-out/bin/boris \
  --input /tmp/obs-mig-report/content \
  --html-dir /tmp/obs-site \
  --quiet
```

Parent graph and wiki targets may still need author follow-up (one-level Trunk /
Satellite rules). See [`docs/MIGRATION.md`](../../docs/MIGRATION.md).

---

## Instagram mode

### Inputs

- **Unpacked Instagram data-download** root (Meta “Download your information”).
- Expects `your_instagram_activity/content/` (or a top-level `content/`) with
  `posts_*.json` / `posts_*.html`, optional `reels*`, `stories*`, `other_content*`.
- Local `media/` tree referenced by export URIs.

### Outputs under `--out`

```text
content/
  instagram.md                 # Trunk
  instagram/<kind>-<id>.md     # one page per post/reel/story/other record
theme/
  layouts/main.html
  footer.html
  assets/css/site.css
  assets/media/...             # copied source media (bytes unchanged)
report.json
REPORT.md
media_manifest.json            # clean provenance for a later enrichment pass (no OCR)
```

Each page uses **closed Boris frontmatter only**: `id`, `title`, `parent`,
`status`, `tags`. Caption bytes, timestamp, source JSON/HTML path, media URIs,
theme asset paths, and conversion notes live in the body + provenance comment.

| Class | Typical cause |
|-------|----------------|
| `exact` | Simple photo record with durable id |
| `transformed` | Carousel, video, reel/story, HTML-source parse |
| `unsupported` | other/unknown archive kinds, malformed JSON placeholder |
| `human_review` | Missing media, empty caption, id collisions |

Synthetic fixture: [`fixtures/mini-instagram/`](fixtures/mini-instagram/).

Compile the generated site with product Boris:

```bash
# from repo root after a successful migration-lab run
./zig-out/bin/boris \
  --input /tmp/ig-mig-report/content \
  --theme /tmp/ig-mig-report/theme \
  --html-dir /tmp/ig-site \
  --quiet
```

---

## WordPress mode

### Inputs

- **WXR/XML export** from Tools → Export in WordPress (or a synthetic fixture).
- **Optional `--media=DIR`** — offline local mirror of `wp-content/uploads/`
  (relative paths like `2024/01/hero.png`). Optional: without it, media refs are
  inventoried as unverified / missing and never invented. **No network fetch**,
  scraping, or WordPress API.

### Outputs under `--out`

```text
content/
  posts.md              # synthetic trunk stub (when posts exist)
  pages.md              # synthetic trunk stub (when pages exist)
  posts/<slug>.md       # migrated posts
  posts/<slug>.assets/… # verified local media copied page-local (when --media matches)
  pages/<slug>.md       # migrated pages
  pages/<slug>.assets/… # same for pages
  _preserved/<type>-<id>.md   # attachments, custom post types, etc.
report.json             # machine-readable (schema_version 3)
REPORT.md               # human-readable twin
media_manifest.json     # deterministic media materialization audit
```

### Local media materialization (`--media`)

When `--media=DIR` contains a **verified** local match for a WordPress upload URL:

1. Copy bytes into the output page’s sibling asset tree
   (`content/posts/example.md` → `content/posts/example.assets/…`).
2. Preserve a deterministic, collision-safe within-tree path (prefer the uploads
   key `YYYY/MM/file.ext` when Boris-safe).
3. Rewrite matching Markdown and retained raw HTML media references to the
   page-local path (`example.assets/YYYY/MM/file.ext`).
4. Record the outcome in `media_manifest.json`.

When media is **unresolved** (missing, ambiguous basename, traversal/symlink/
absolute escape, or no `--media`):

- Do **not** invent a path or silently remove the reference.
- Leave the original reference visible in the page body.
- Keep the human-review finding and `missing_media` / manifest entry.

| Status | Meaning |
|--------|---------|
| `copied` | Verified local file written under `{stem}.assets/` + reference rewritten |
| `missing` | No safe local match (or `--media` omitted) |
| `ambiguous` | Multiple local files share the basename; no automatic choice |
| `rejected` | Traversal, absolute/`file:` escape, symlink, collision, or attachment-inventory-only |

Security: rejects path traversal, absolute escapes, and symlink escapes from the
media source tree; never overwrites colliding destinations with different bytes.
Query strings and fragments on matched URLs are **dropped** on rewrite (Boris
content-local asset grammar); the manifest reason records `query_string_dropped`
/ `fragment_dropped`. The same source file used by two pages is **copied per
page** (Boris-native page-local ownership).

`media_manifest.json` fields (per entry): `source_output`, `original_reference`,
`upload_key`, `matched_source`, `emitted_asset_path`, `status`, `reason`.

This is **developer migration tooling**, not Boris runtime functionality. The
product compiler only publishes sibling `{stem}.assets/` trees that already
satisfy [`docs/contracts/content-local-assets.md`](../../docs/contracts/content-local-assets.md).

Every generated Markdown file includes:

- **Boris closed frontmatter** (`title`, optional `parent`, `status`, `tags`)
- A **`boris-migration-provenance`** HTML comment (source export path, post_id,
  type, guid, author, dates, conversion class)
- **WordPress excerpt** (when present) as a labeled blockquote before the body —
  not a closed frontmatter field
- Converted body (HTML → Markdown where possible; raw HTML/shortcodes retained as
  unsupported artifacts — never silently expanded offline)

### Conversion classes

| Class | Meaning |
|-------|---------|
| `exact` | No material transform (empty/plain body or synthetic stubs) |
| `transformed` | Known HTML/block mappings applied (including excerpt preservation) |
| `unsupported` | Shortcodes, embeds, comments, menus, post formats, widgets, or non post/page types preserved raw — **not** silent meaning-preserving Markdown |
| `human_review` | Author judgment needed (statuses, sticky, missing media, deep hierarchy, empty/long titles, empty slugs, slug conflicts, unresolved links) |

Overall page class is the **worst** feature rank. Features are also listed
individually under `features` in `report.json`.

### WordPress statuses

| `wp:status` / flag | Boris `status` | Feature code |
|--------------------|----------------|--------------|
| `publish` | `published` | _(none)_ |
| `draft` / `auto-draft` | `draft` | `status_draft` |
| `future` (scheduled) | `draft` | `status_future` |
| `private` | `draft` | `status_private` |
| `pending` | `draft` | `status_pending` |
| non-empty `wp:post_password` | `draft` (even if publish) | `status_password_protected` |

### Field preservation (schema 3)

| WXR field | Output | If missing / special |
|-----------|--------|----------------------|
| `title` | Frontmatter `title` | Empty → slug fallback + `empty_title` |
| `wp:post_name` | Entity slug + report `source_slug` | Empty → synthesize from title + `empty_slug` |
| `wp:post_date` / `_gmt` | Provenance + report | Always recorded when present |
| `excerpt:encoded` | Body blockquote + report `excerpt` | Empty → omitted; never invented |
| body (`content:encoded`) | Markdown/HTML body | Empty → `empty_body` |
| categories / tags | Report lists; merged into closed `tags` | Post formats **excluded** from tags |
| `wp:is_sticky` | Report `is_sticky` | Sticky → `sticky_post` human review |

### Explicit unsupported / review artifacts

These must **not** be folded into ordinary page Markdown as if converted:

| Artifact | Treatment |
|----------|-----------|
| Comments / trackbacks / pingbacks | `comments[]` + `content/_preserved/comments-<post_id>.md`; page body untouched |
| `nav_menu_item` | `_preserved/` + feature `wp_menu` |
| Post formats (`domain="post_format"`) | Feature `post_format`; **not** added to Boris `tags` |
| Widgets | Feature `wp_widget`; raw shortcode/HTML kept |
| Shortcodes (`[gallery]`, `[audio]`, `[video]`, …) | Left raw; classification `unsupported` |
| Empty title / empty body / long title | `empty_title`, `empty_body`, `long_title` |
| Empty / missing slug | `empty_slug` (synthesized path still emitted) |
| Sticky flag | `sticky_post` (no Boris sticky frontmatter) |
| Excerpt | Preserved in body + report (`excerpt_preserved`); not closed FM |

### Report sections (WordPress)

| Section | Contents |
|---------|----------|
| `authors` | WXR authors |
| `taxonomies` | Categories, tags, and non-duplicate `wp:term` rows (e.g. `nav_menu`) |
| `taxonomy_stats` | Counts + `high_cardinality` vs threshold (schema 2) |
| `pages` | Posts/pages (+ trunk stubs): dates, authors, slugs, categories, tags, proposed frontmatter, conversion |
| `parent_relationships` | `wp:post_parent` → proposed Boris `parent` (one-hop graph notes) |
| `links` | Internal (and site-local) hrefs with resolution status |
| `media_references` / `missing_media` | Image/audio/video/attachment refs vs optional `--media` tree |
| `media_manifest.json` (sidecar) | Materialization audit: copied / missing / ambiguous / rejected |
| `features` | Raw HTML, shortcodes, embeds, galleries, comments, formats, statuses |
| `slug_conflicts` | Duplicate `post_name` values |
| `unsupported_items` | Custom types/attachments/comments preserved under `_preserved/` |
| `comments` | Comment/trackback/pingback index (schema 2); not page bodies |
| `human_review` | Aggregated review queue |
| `provenance` | One record per generated file |

### Proposed entity ids

| Source | Rule |
|--------|------|
| `post` | `posts/<post_name>` |
| `page` | `pages/<post_name>` |
| Trunk stubs | `posts`, `pages` |

Boris only allows **one** parent hop (Trunk ← Satellite). Deep WordPress page
trees are flattened with `human_review` notes.

### Fixtures

| Fixture | Role |
|---------|------|
| [`fixtures/unit-wxr/`](fixtures/unit-wxr/) | **Unit matrix** — one item per high-value preserve/report behavior (posts/pages, dates, excerpt, sticky, empty slug/title, statuses, shortcodes, comments/trackbacks/pingbacks, hierarchy, duplicates, media, attachments, menus) |
| [`fixtures/mini-wxr/`](fixtures/mini-wxr/) | Small happy-path + shortcode/media/draft matrix |
| [`fixtures/media-wxr/`](fixtures/media-wxr/) | **Media materialization** — full/relative uploads match, shared asset across pages, nested page assets, missing, ambiguous basename, traversal/absolute escapes, query/fragment drop |
| [`fixtures/adversarial-wxr/`](fixtures/adversarial-wxr/) | Unicode, slug collisions, deep pages, duplicate media basenames |
| [`fixtures/wptt-derived/`](fixtures/wptt-derived/) | Hostile WPTT-class gaps (taxonomy cardinality, long titles, widgets, empty body). **Does not** vendor the full upstream WXR |

Hostile offline dogfood (operator machine, not CI):

```bash
# Download WPTT outside the repo — do not commit
curl -fsSL -o /tmp/themeunittestdata.wordpress.xml \
  https://raw.githubusercontent.com/WPTT/theme-unit-test/master/themeunittestdata.wordpress.xml
zig build run -- --mode=wordpress \
  --wxr=/tmp/themeunittestdata.wordpress.xml --out=/tmp/wp-wptt-out
```

```bash
# Unit matrix (CI-friendly)
zig build run -- --wxr=./fixtures/unit-wxr/export.xml \
  --media=./fixtures/unit-wxr/media --out=./.wp-unit-report
```

---

## Astro mode

Read-only archaeology over an Astro project/export tree. Emits `report.json` +
`REPORT.md` only — **no** Markdown rewrite, **no** network, **no** Astro config
evaluation.

### Content-root selection

Markdown/MDX content pages are discovered **only** under well-known Astro
content-collection directories. Arbitrary repository Markdown (`README.md`,
`docs/`, notes trees, …) is never treated as content.

| Priority | Root (scan-root relative) | Role |
|----------|---------------------------|------|
| 1 | `src/content/` | Canonical Astro content collections |
| 2 | `content/` | Root-level collections used by some Astro layouts |

Rules:

1. Each candidate is used **only if it exists as a directory** under `--root`.
2. `.md` / `.mdx` files under every existing candidate are inventoried as
   `content_page` (entity id = path under that root with extension stripped).
3. When **both** roots exist, pages under each are inventoried and a high
   severity `ambiguous_content_roots` hazard is emitted for human review.
4. Config markers such as `src/content/config.ts` and `content/config.ts` are
   classified as `config`, not content pages.

Other inventory classes (unchanged): `src/pages/**/*.astro` → `page_route`,
`src/layouts/` → `layout`, `src/components/` → `component`, `public/` →
`public_asset`, `src/assets/` → `src_asset`.

### Absolute link classification

Site-root absolute targets (`/…`) are **not** blindly mapped to `public/`.

| Kind | Absolute target | Resolution |
|------|-----------------|------------|
| `markdown_image` / `html_src` | `/images/hero.png` | `public/images/hero.png` — missing → `missing_assets` |
| `markdown_link` / `html_href` | existing file under `public/` | treated as present asset |
| `markdown_link` / `html_href` | `/`, `/about`, `/docs/…` | evaluated as route/page (content roots + `src/pages/`) |
| `markdown_link` / `html_href` | missing route e.g. `/no-such-page` | **`broken_links`**, not `missing_assets` |

Relative image/src handling is unchanged (resolved against the source file path).

### Documented limitations (human review / future work)

These are **out of scope** for the archaeology lab and must not be mistaken for
silent success:

- **tsconfig / import-alias resolution** (`@/`, `~/`, package subpath imports)
- **Dynamic-route stitch disambiguation** beyond “zero or one matching dynamic
  route” (multiple `[slug]` / `[...slug]` owners → incomplete stitch note)
- **General Astro config evaluation** (`astro.config.*` content collections
  overrides, custom `srcDir`, i18n path prefixes, middleware rewrites)
- **Runtime / SSR-only routes** and endpoint handlers (`.ts` API routes)

### Fixtures

| Fixture | Role |
|---------|------|
| [`fixtures/mini-astro/`](fixtures/mini-astro/) | Happy-path collections under `src/content/`, stitches, hazards |
| [`fixtures/root-content-astro/`](fixtures/root-content-astro/) | Root-level `content/` discovery (no `src/content/`) |
| [`fixtures/absolute-links-astro/`](fixtures/absolute-links-astro/) | `/`, `/about`, missing route vs public image assets |
| [`fixtures/dual-content-roots-astro/`](fixtures/dual-content-roots-astro/) | Both content roots + free-form `NOTES.md` ignored |
| [`fixtures/adversarial-astro/`](fixtures/adversarial-astro/) | Unicode paths, route ambiguity, JSX hazards |

```bash
zig build run -- --mode=astro --root=./fixtures/root-content-astro --out=./.migration-report-root
zig build run -- --mode=astro --root=./fixtures/absolute-links-astro --out=./.migration-report-abs
```

---

## Relationship to Boris product rules

- Implemented in **Zig only** (no Node/Python migration stage).
- Lives under `tools/` so it cannot be mistaken for the content compiler.
- Does not modify `src/`, `docs/contracts/`, root `build.zig`, or default CI gates.
- Generated frontmatter targets the closed author grammar (`id`, `title`,
  `parent`, `status`, `tags`) from [`docs/contracts/frontmatter.md`](../../docs/contracts/frontmatter.md).
- Conversion still follows [`docs/MIGRATION.md`](../../docs/MIGRATION.md) for
  author follow-up (wiki links, includes, theme).

## Schema note

WordPress `report.json` top-level fields (stable order, **schema 3**):

```text
format, schema_version, tool_version, source_export, media_dir,
site_title, base_site_url, base_blog_url, summary, authors, taxonomies,
taxonomy_stats, pages, parent_relationships, links, media_references,
missing_media, features, slug_conflicts, unsupported_items, comments,
human_review, provenance
```

Per-page fields (schema 3) include `source_slug`, `post_date_gmt`, `excerpt`,
and `is_sticky` in addition to title/slug/status/taxonomy/conversion fields.

Obsidian `report.json` top-level fields (stable order):

```text
format, schema_version, tool_version, source_vault, summary,
pages, links, hazards, attachments, unsupported_items, human_review
```

Notion `report.json` top-level fields (stable order):

```text
format, schema_version, tool_version, source_export, summary,
pages, links, hazards, media, unsupported_items, human_review
```

Bump `schema_version` if field meaning or required shape changes.
