# boris-migration-lab

Standalone **migration laboratory** for bringing existing sites into Boris.

| Mode | Input | Output |
|------|--------|--------|
| **astro** | Astro project/export tree | Deterministic archaeology `report.json` + `REPORT.md` |
| **wordpress** | WordPress WXR/XML + optional local media | Boris-ready Markdown under `content/` + review reports |

Both modes are **read-only on inputs**: originals are never rewritten. There is
**no network access** and **no product compiler coupling**. All code and fixtures
live under `tools/migration-lab/`.

| | |
|--|--|
| Source | `tools/migration-lab/` |
| Binary | `zig-out/bin/boris-migration-lab` (local package install) |
| Build | `zig build` from this directory |
| Tests | `zig build test` from this directory |
| Astro format id | `boris-astro-migration-lab` |
| WordPress format id | `boris-wordpress-migration-lab` |
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
```

From the **repository root**:

```bash
zig build -C tools/migration-lab
zig build -C tools/migration-lab test
zig build -C tools/migration-lab run -- \
  --wxr=tools/migration-lab/fixtures/mini-wxr/export.xml \
  --media=tools/migration-lab/fixtures/mini-wxr/media \
  --out=/tmp/wp-mig-report
```

### Flags

| Flag | Default | Meaning |
|------|---------|---------|
| `-h`, `--help` | | Print usage; exit 0 |
| `-q`, `--quiet` | off | Suppress progress lines |
| `--mode=MODE` | `astro` | `astro` or `wordpress` (`wp` / `wxr` aliases) |
| `--out=DIR` | `migration-report` | Output directory (**must differ from inputs**) |
| `--root=DIR` | `.` | Astro scan root |
| `--wxr=FILE` | | WordPress WXR/XML path (implies `--mode=wordpress`) |
| `--media=DIR` | | Optional local media/uploads tree (WordPress) |

Exit codes: **0** success, **2** usage, **3** I/O error.

---

## Safety rules

1. **Preserve originals** — only writes under `--out`.
2. **No network** — no fetches, no package installs, no oEmbed expansion.
3. **No destructive source ops** — no delete/rename of WXR, media, or scan-root files.
4. **No product coupling** — does not import `src/` compiler modules; not in root `zig build test`.
5. **Deterministic** — sorted ids/paths; fixed field order; no host timestamps in report bodies.
6. **Never silently discard** — unsupported items are preserved under `content/_preserved/` and listed in the report.

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

Bump `schema_version` if field meaning or required shape changes.
