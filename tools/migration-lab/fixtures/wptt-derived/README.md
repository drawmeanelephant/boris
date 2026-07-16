# wptt-derived fixture

Compact **redistributable** WordPress WXR derived from gaps confirmed while
running the official [WPTT Theme Unit Test](https://github.com/WPTT/theme-unit-test)
export **offline** (download outside the repo; do not commit the full upstream
file).

| Path | Role |
|------|------|
| `export.xml` | Synthetic WXR (~27KB) covering hostile cases below |
| `media/2024/01/hero.png` | Present local upload |
| _(no missing-track.mp3 / missing-clip.mp4)_ | Intentionally absent |

## Why not vendor WPTT?

- The full Theme Unit Test WXR is large and pulls remote media hosts.
- Upstream is GPL; shipping the entire dump as a product fixture is unnecessary
  when small synthetic cases reproduce the same importer defects.
- Operators who want the full corpus:

```bash
# Outside Boris — never commit the download
curl -fsSL -o /tmp/themeunittestdata.wordpress.xml \
  https://raw.githubusercontent.com/WPTT/theme-unit-test/master/themeunittestdata.wordpress.xml

zig build --build-file tools/migration-lab/build.zig run -- \
  --mode=wordpress \
  --wxr=/tmp/themeunittestdata.wordpress.xml \
  --out=/tmp/wp-wptt-out
```

## Coverage matrix (confirmed gaps → fixtures)

Primary unit matrix (excerpts, sticky, empty slug, pingbacks, field
preservation): see [`../unit-wxr/`](../unit-wxr/). This fixture keeps the
**hostile / high-cardinality** WPTT-class gaps:

| Gap | How it appears here | Importer expectation |
|-----|---------------------|----------------------|
| Determinism + source immutability | Double-run tests | Byte-identical `report.json`; export/media untouched |
| Empty title + empty body | post_id 6 | `empty_title`, `empty_body`; slug title fallback; no invented prose |
| Long title | Maori place-name style title (post 7) | `long_title` human_review |
| Unicode title | Café 🧪 (post 9) | Title preserved; slug sanitized |
| Title HTML entities | Special-characters title (post 8) | Decoded in frontmatter (`&` not `&amp;`) |
| Statuses | publish / draft / future / private / password | `status_*` codes; password → Boris `draft` |
| One-level parents | About → Team → Engineering | Child→parent medium; deep hop → `deep_page_hierarchy` |
| High-cardinality taxonomies | 40 categories + 20 tags + nav_menu term | `taxonomy_stats` + `high_cardinality_taxonomy` |
| High-cardinality terms on a page | post 7 with 17 categories | `high_cardinality_terms` |
| Media present / missing | hero.png present; mp3/mp4 missing | `present` / `missing_media` |
| Galleries / audio / video | `[gallery]`, `[audio]`, `[video]`, `<audio>` | Shortcodes **raw** + `unsupported` (not silent MD) |
| Comments + trackbacks | on Hello | `comments` report + `_preserved/comments-*.md`; **not** in page body |
| Menus | `nav_menu_item` 1100 | `wp_menu` + `_preserved/` |
| Widgets | `[widget id=…]` | `wp_widget` unsupported |
| Post formats | `domain="post_format"` | `post_format` unsupported; **not** merged into tags |
| Attachments | post_id 10 | Preserved inventory under `_preserved/` |

## Run

```bash
cd tools/migration-lab
zig build test
zig build run -- --wxr=./fixtures/wptt-derived/export.xml \
  --media=./fixtures/wptt-derived/media --out=./.wp-report
```
