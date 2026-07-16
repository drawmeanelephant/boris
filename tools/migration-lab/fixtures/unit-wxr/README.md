# unit-wxr fixture

Compact **redistributable unit-matrix** WordPress WXR for
`boris-migration-lab --mode=wordpress`. Derived from gaps and inventory cases
confirmed while running the official
[WPTT Theme Unit Test](https://github.com/WPTT/theme-unit-test) export
**offline** (download outside the repo; do not commit the full upstream file).

| Path | Role |
|------|------|
| `export.xml` | Synthetic WXR (~12KB) — one item per high-value behavior |
| `media/2024/01/hero.png` | Present local upload |
| _(no missing-asset.png)_ | Intentionally absent |

## Why not vendor WPTT?

- The full Theme Unit Test WXR is large and references remote media hosts.
- Upstream is GPL; shipping the entire dump as a product fixture is unnecessary
  when small synthetic cases reproduce the same importer behaviors.
- Operators who want the full corpus:

```bash
# Outside Boris — never commit the download
curl -fsSL -o /tmp/themeunittestdata.wordpress.xml \
  https://raw.githubusercontent.com/WPTT/theme-unit-test/master/themeunittestdata.wordpress.xml

zig build -C tools/migration-lab run -- \
  --mode=wordpress \
  --wxr=/tmp/themeunittestdata.wordpress.xml \
  --out=/tmp/wp-wptt-out
```

## Coverage matrix

| Case | post_id | Expected behavior |
|------|---------|-------------------|
| Post vs page | 1 / 20 | `posts/<slug>.md` vs `pages/<slug>.md` + trunk stubs |
| Dates / slug / title / body | 1 | Report fields + provenance; body converted |
| Excerpt | 1, 20 | `excerpt` in `report.json`; body blockquote; code `excerpt_preserved` |
| Categories + tags | 1 | Closed `tags:` merge; domains preserved in report |
| Sticky | 2 | `is_sticky: true`; feature `sticky_post` (review) |
| Empty slug | 3 | Synthesized slug; feature `empty_slug` (review) |
| Empty title | 4 | Title fallback to slug; feature `empty_title` |
| Draft | 3 | Boris `draft`; `status_draft` |
| Future | 5 | Boris `draft`; `status_future` |
| Private | 6 | Boris `draft`; `status_private` |
| Password | 7 | Boris `draft`; `status_password_protected` |
| Gallery / shortcodes / widget | 8 | Raw body preserve; `unsupported` features |
| Post format | 8 | `post_format` feature; **not** merged into tags |
| Comments / trackbacks / pingbacks | 8 | `_preserved/comments-8.md`; **not** page body |
| Parent/child pages | 20→21 | `parent` medium confidence |
| Deep page hierarchy | 21→22 | `deep_page_hierarchy`; parent trunk |
| Duplicate slugs | 30, 31 | Disambiguated paths + `slug_conflicts` |
| Missing media | 31 | `missing_media` / `missing_media` feature |
| Present media | 1 | `media_references` status `present` |
| Attachment | 90 | `_preserved/attachment-90.md` |
| Menu item | 1100 | `_preserved/nav_menu_item-1100.md` + `wp_menu` |

### Deliberate policy (no silent data loss)

| Construct | Policy |
|-----------|--------|
| Title, slug, dates, body, categories, tags | **Preserve** into Markdown / report |
| Excerpt | **Preserve** in body + report (not closed frontmatter) |
| Sticky | **Report** (`sticky_post`) — no Boris equivalent |
| Draft / future / private / password | **Map** to Boris `draft` + **report** status code |
| Empty title / empty slug | **Synthesize** fallback + **report** |
| Duplicate slug | **Disambiguate** output path + **report** conflict |
| Gallery, shortcodes, widgets, post formats | **Preserve raw** + **report** unsupported |
| Comments / trackbacks / pingbacks | **Preserve** under `_preserved/` + **report** (never page body) |
| Attachments / menus / custom types | **Preserve** under `_preserved/` + **report** |
| Missing media | **Report** (never invent bytes) |

## Run

```bash
cd tools/migration-lab
zig build test
zig build run -- --wxr=./fixtures/unit-wxr/export.xml \
  --media=./fixtures/unit-wxr/media --out=./.wp-unit-report
```
