# media-wxr fixture

Synthetic WordPress WXR + local media tree for **media materialization** tests
(`boris-migration-lab --mode=wordpress --media=…`).

| Path | Role |
|------|------|
| `export.xml` | WXR with present, missing, shared, nested, ambiguous, and escape refs |
| `media/2024/01/hero.png` | Present upload (also used with query/fragment) |
| `media/2024/01/shared.png` | Same asset referenced by two posts |
| `media/2024/06/diagram.png` | Nested page (`pages/nested-diagram`) asset |
| `media/2025/02/hero.png` | Second `hero.png` (duplicate basename inventory) |
| _(no gone.png)_ | Missing-media case |

## Coverage

| Case | Source signal |
|------|----------------|
| Full `wp-content/uploads/YYYY/MM/file` match | post `full-upload` |
| Relative `uploads/…` match | post `relative-uploads` |
| One source asset → two pages (per-page copy) | `shared.png` on posts 2 and 3 |
| Nested page output | `pages/nested-diagram` → `content/pages/nested-diagram.assets/…` |
| Missing media | post `missing-media` keeps original URL |
| Duplicate basename / ambiguous | post `ambiguous-basename` + two `hero.png` files |
| Traversal escape | post `traversal-escape` |
| Absolute / `file:` escape | post `absolute-escape` |
| Query dropped, fragment kept | post `query-fragment` |

Symlink-escape coverage is created at test runtime (not committed).

```bash
zig build run -- --wxr=./fixtures/media-wxr/export.xml \
  --media=./fixtures/media-wxr/media --out=./.wp-media-report
```
