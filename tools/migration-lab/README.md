# boris-migration-lab

Standalone **migration laboratory** for bringing existing sites into Boris.

| Mode | Input | Output |
|------|--------|--------|
| **astro** | Astro project/export tree | Deterministic archaeology `report.json` + `REPORT.md` |
| **wordpress** | WordPress WXR/XML + optional local media | Boris-ready Markdown under `content/` + review reports |
| **instagram** | Unpacked Instagram data-download (Takeout) | Boris Markdown + generated theme assets + reports |
| **obsidian** | Local Obsidian vault directory | Boris Markdown + attachments inventory + review reports |
| **notion** | Official Notion “Markdown & CSV” export (unpacked) | Boris Markdown + media inventory + review reports |

All modes are **read-only on inputs**: originals are never rewritten. There is
**no network access**, no zip extraction, no scraping, and **no product compiler
coupling**. All code and fixtures live under `tools/migration-lab/`.

| | |
|--|--|
| Source | `tools/migration-lab/` |
| Binary | `zig-out/bin/boris-migration-lab` (local package install) |
| Build | `zig build` from this directory |
| Tests | `zig build test` from this directory |
| Astro format id | `boris-astro-migration-lab` |
| WordPress format id | `boris-wordpress-migration-lab` |
| Instagram format id | `boris-instagram-migration-lab` |
| Obsidian format id | `boris-obsidian-migration-lab` |
| Notion format id | `boris-notion-migration-lab` |
| Schema | `1` (per mode) |

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
```

From the **repository root**:

```bash
zig build -C tools/migration-lab
zig build -C tools/migration-lab test
zig build -C tools/migration-lab run -- \
  --wxr=tools/migration-lab/fixtures/mini-wxr/export.xml \
  --media=tools/migration-lab/fixtures/mini-wxr/media \
  --out=/tmp/wp-mig-report
zig build -C tools/migration-lab run -- \
  --mode=instagram \
  --dump=tools/migration-lab/fixtures/mini-instagram \
  --out=/tmp/ig-mig-report
zig build -C tools/migration-lab run -- \
  --mode=obsidian \
  --vault=tools/migration-lab/fixtures/mini-obsidian \
  --out=/tmp/obs-mig-report
zig build -C tools/migration-lab run -- \
  --mode=notion \
  --export=tools/migration-lab/fixtures/mini-notion \
  --out=/tmp/notion-mig-report
```

### Flags

| Flag | Default | Meaning |
|------|---------|---------|
| `-h`, `--help` | | Print usage; exit 0 |
| `-q`, `--quiet` | off | Suppress progress lines |
| `--mode=MODE` | `astro` | `astro`, `wordpress` (`wp` / `wxr`), `instagram` (`ig` / `takeout`), `obsidian` (`obs` / `vault`), or `notion` (`md-csv` / `notion-export`) |
| `--out=DIR` | `migration-report` | Output directory (**must differ from inputs**) |
| `--root=DIR` | `.` | Astro scan root |
| `--wxr=FILE` | | WordPress WXR/XML path (implies `--mode=wordpress`) |
| `--media=DIR` | | Optional local media/uploads tree (WordPress) |
| `--dump=DIR` | | Unpacked Instagram data-download root (implies `--mode=instagram`) |
| `--vault=DIR` | | Obsidian vault root (implies `--mode=obsidian`) |
| `--export=DIR` | | Unpacked Notion Markdown & CSV export root (implies `--mode=notion`) |

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

---

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
- **Optional media directory** mirroring `wp-content/uploads/` (relative paths like
  `2024/01/hero.png`).

### Outputs under `--out`

```text
content/
  posts.md              # synthetic trunk stub (when posts exist)
  pages.md              # synthetic trunk stub (when pages exist)
  posts/<slug>.md       # migrated posts
  pages/<slug>.md       # migrated pages
  _preserved/<type>-<id>.md   # attachments, custom post types, etc.
report.json             # machine-readable (schema_version 1)
REPORT.md               # human-readable twin
```

Every generated Markdown file includes:

- **Boris closed frontmatter** (`title`, optional `parent`, `status`, `tags`)
- A **`boris-migration-provenance`** HTML comment (source export path, post_id,
  type, guid, author, dates, conversion class)
- Converted body (HTML → Markdown where possible; raw HTML/shortcodes retained)

### Conversion classes

| Class | Meaning |
|-------|---------|
| `exact` | No material transform (empty/plain body or synthetic stubs) |
| `transformed` | Known HTML/block mappings applied |
| `unsupported` | Shortcodes, embeds, custom blocks, or non post/page types preserved raw |
| `human_review` | Author judgment needed (drafts, missing media, deep hierarchy, slug conflicts, unresolved links) |

Overall page class is the **worst** feature rank. Features are also listed
individually under `features` in `report.json`.

### Report sections (WordPress)

| Section | Contents |
|---------|----------|
| `authors` | WXR authors |
| `taxonomies` | Categories and tags from export |
| `pages` | Posts/pages (+ trunk stubs): dates, authors, slugs, categories, tags, proposed frontmatter, conversion |
| `parent_relationships` | `wp:post_parent` → proposed Boris `parent` (one-hop graph notes) |
| `links` | Internal (and site-local) hrefs with resolution status |
| `media_references` / `missing_media` | Image/attachment refs vs optional `--media` tree |
| `features` | Raw HTML, shortcodes, embeds, galleries, Gutenberg blocks |
| `slug_conflicts` | Duplicate `post_name` values |
| `unsupported_items` | Custom types/attachments preserved under `_preserved/` |
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

### Fixture

[`fixtures/mini-wxr/`](fixtures/mini-wxr/) — synthetic WXR + partial media tree.
See its README for the coverage matrix.

---

## Astro mode

Scans typical Astro trees (`src/content`, `src/pages`, layouts, assets) and
emits archaeology-only reports (no Markdown rewrite). See the Astro sections in
git history / prior README content for stitch model and hazard codes.

Fixture: [`fixtures/mini-astro/`](fixtures/mini-astro/).

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

WordPress `report.json` top-level fields (stable order):

```text
format, schema_version, tool_version, source_export, media_dir,
site_title, base_site_url, base_blog_url, summary, authors, taxonomies,
pages, parent_relationships, links, media_references, missing_media,
features, slug_conflicts, unsupported_items, human_review, provenance
```

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
