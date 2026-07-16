# mini-wxr fixture

Synthetic WordPress WXR export for `boris-migration-lab --mode=wordpress`.

| Path | Role |
|------|------|
| `export.xml` | WXR 1.2-style export (never rewritten by the tool) |
| `media/2024/01/hero.png` | Local media present for matching |
| _(no missing-asset.png)_ | Intentionally absent for missing-media tests |

## Coverage matrix

| Signal | Where |
|--------|--------|
| Posts + pages | post_ids 1–7 |
| Authors | `admin`, `writer` |
| Categories + tags | `news`, `releases`, `migration`, `boris` |
| Page parent chain | About → Team → Engineering (deep hierarchy) |
| Internal links | Hello World ↔ About; broken `/gone/` |
| Media present | `hero.png` |
| Media missing | `missing-asset.png` |
| Shortcodes | `[gallery]`, `[caption]`, `[embed]` |
| Gutenberg | `wp:paragraph`, `wp:image`, `wp:embed` |
| Draft status | Draft Ideas |
| Duplicate slug | `hello-world` on post and page |
| Custom post type | `product` → preserved under `_preserved/` |
| Attachments | post_ids 10–11 |

For statuses (future/private/password), comments, post formats, menus, empty
titles, and high-cardinality taxonomies, see
[`../wptt-derived/`](../wptt-derived/).

Run from `tools/migration-lab/`:

```bash
zig build run -- --wxr=./fixtures/mini-wxr/export.xml \
  --media=./fixtures/mini-wxr/media --out=./.wp-report
zig build test
```
