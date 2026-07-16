# boris-migration-lab

Standalone **Astro → Boris migration archaeology** tool.

Scans a real (or synthetic) Astro project/export tree and produces **deterministic**
JSON + Markdown reports. It is **read-only**: originals are never rewritten.

This tool is **not** the Boris content compiler, does **not** change product IR
or contracts, and is **not** wired into the root `zig build` / `zig build test`
default gate. All code and fixtures live under `tools/migration-lab/`.

| | |
|--|--|
| Source | `tools/migration-lab/` |
| Binary | `zig-out/bin/boris-migration-lab` (local package install) |
| Build | `zig build` from this directory |
| Tests | `zig build test` from this directory |
| Format id | `boris-astro-migration-lab` |
| Schema | `1` |

Companion author guide for content conversion (product docs):
[`docs/MIGRATION.md`](../../docs/MIGRATION.md).

---

## Quick start

From **`tools/migration-lab/`** (Zig **0.16+**):

```bash
zig build
zig build run -- --root=./fixtures/mini-astro --out=./.migration-report
zig build test
```

From the **repository root**:

```bash
zig build -C tools/migration-lab
zig build -C tools/migration-lab run -- --root=tools/migration-lab/fixtures/mini-astro --out=/tmp/astro-mig-report
zig build -C tools/migration-lab test
```

### Flags

| Flag | Default | Meaning |
|------|---------|---------|
| `-h`, `--help` | | Print usage; exit 0 |
| `-q`, `--quiet` | off | Suppress progress lines |
| `--root=DIR` | `.` | Astro project/export root to scan |
| `--out=DIR` | `migration-report` | Report directory (**must differ from `--root`**) |

Exit codes: **0** success, **2** usage, **3** I/O error.

---

## Safety rules

1. **Preserve originals** — only writes under `--out`.
2. **No network** — no fetches, no package installs.
3. **No destructive source ops** — no delete/rename of scan-root files.
4. **No product coupling** — does not import `src/` compiler modules.
5. **Deterministic** — sorted paths; fixed field order; no timestamps/host paths
   in report bodies (`scan_root` echoes the user-supplied `--root` string).

---

## What is scanned

Typical Astro shapes under `--root`:

| Path | Classification |
|------|----------------|
| `src/content/**/*.{md,mdx}` | Content collection pages |
| `src/pages/**/*.astro` | Page routes (including `[slug]` / `[...slug]`) |
| `src/layouts/**/*.astro` | Layouts |
| `src/components/**` | Components (inventory) |
| `src/assets/**` | Source assets |
| `public/**` | Public/static assets |
| `astro.config.*`, `src/content/config.*`, `package.json` | Config markers |

Skipped directory names include `node_modules`, `.git`, `.astro`, `dist`, and
common deploy output folders.

---

## Reports

Under `--out`:

```text
report.json   # machine-readable, schema_version 1
REPORT.md     # human-readable twin
```

### Report sections

| Section | Contents |
|---------|----------|
| `inventory` | Every discovered file with kind, bytes, extension, `source_path` |
| `stitches` | Three-file stitch: **content** + **route** + **layout** per logical page |
| `proposed_ids` | Suggested Boris entity ids (path-derived under content/pages) |
| `parent_child_candidates` | From `parent` / legacy `parentEntry` / directory hierarchy |
| `links` | Internal markdown/HTML links and image refs with line numbers |
| `broken_links` | Internal targets that do not resolve in the tree |
| `slug_conflicts` | Duplicate collection-relative slugs (and case collisions) |
| `assets` | Public + `src/assets` inventory |
| `missing_assets` | Asset references with no matching file |
| `hazards` | Frontmatter/content conversion risks vs Boris closed grammar |
| `human_review` | Aggregated queue of pages needing author judgment |

Every finding carries **source-relative provenance** (`source_path` relative to
the scan root).

### Three-file stitch model

Astro documentation pages are often composed of three cooperating files:

1. **Content** — `src/content/<collection>/….{md,mdx}`
2. **Route** — exact `src/pages/…` match or a dynamic collection route
   (`[slug].astro` / `[...slug].astro`)
3. **Layout** — frontmatter `layout:` (resolved) or a preferred default under
   `src/layouts/`

The report records whether each triple is complete and notes missing pieces.
Standalone `.astro` routes without content entries are listed as incomplete
stitches for review.

### Proposed entity ids

| Source | Rule |
|--------|------|
| `src/content/<collection>/<path>.md(x)` | `<collection>/<path>` (extension stripped) |
| `src/pages/<path>.astro` (non-dynamic) | `<path>` (`index` → `index`) |

These are **proposals** for Boris path-derived ids, not writes into content.

### Hazard codes (non-exhaustive)

| Code | Why it matters for Boris |
|------|---------------------------|
| `mdx_source` / `mdx_import` / `mdx_export` / `jsx_component` | MDX/JSX is not Boris Markdown |
| `astro_layout_key` | `layout:` is not a Boris author frontmatter key |
| `legacy_parent_key` | `parentEntry` / `parent_entry` → `EFRONTMATTER` |
| `draft_flag` | Map `draft:` → `status: draft` |
| `nested_yaml` / `yaml_sequence` / `block_scalar` | Closed one-line grammar only |
| `unknown_frontmatter_key` | Only `id`, `title`, `parent`, `status`, `tags` |
| `utf8_bom` | BOM rejected |

---

## Fixture

[`fixtures/mini-astro/`](fixtures/mini-astro/) is a synthetic Astro tree used by
`zig build test`. It deliberately includes complete stitches, incomplete
stitches, MDX hazards, nested YAML, duplicate slugs, broken links, and missing
assets. See its README for the matrix.

---

## Relationship to Boris product rules

- Implemented in **Zig only** (no Node/Python archaeology stage).
- Lives under `tools/` so it cannot be mistaken for the content compiler.
- Does not modify `src/`, `docs/contracts/`, root `build.zig`, or default CI gates.
- Conversion still follows [`docs/MIGRATION.md`](../../docs/MIGRATION.md) and
  normative contracts under `docs/contracts/`.

---

## Schema note

`report.json` top-level fields (stable order):

```text
format, schema_version, tool_version, scan_root, summary,
inventory, stitches, proposed_ids, parent_child_candidates,
links, broken_links, slug_conflicts, assets, missing_assets,
hazards, human_review
```

Bump `schema_version` if field meaning or required shape changes.
