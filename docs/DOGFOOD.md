# Real-site dogfood (private)

Boris’s product sample tree stays under root `content/`. **Personal / large
archives** used to dogfood the compiler live outside that path and stay out of
git.

| Path | Role | Git |
|------|------|-----|
| [`SUPPORT/`](../SUPPORT/) | Raw dumps (Instagram export, future lists, notes) | **ignored** |
| [`dogfood/`](../dogfood/) | Generated site + importer working tree | **ignored** |
| Root `content/` | Product docs dogfood | tracked |

## Privacy

Instagram (and similar) exports contain **more than posts**: DMs, logins,
followers, device tables, ads. Dogfood import must use **only** author-facing
post bodies + media. Never copy messages, security, or contacts into the site.

## Spike workflow (Instagram → Boris)

Requires: `zig build` → `./zig-out/bin/boris`, Python 3 (offline parse helper
only — not a product dependency), and a dump under `SUPPORT/`.

```bash
# 1) Import newest N posts into a private site tree
python3 tools/dogfood-instagram-import/import_posts.py \
  --dump SUPPORT/instagram-drawmeanelephant69420-2025-01-07-eCa0Yz6p \
  --out dogfood/site \
  --limit 10

# 2) Compile with Boris
./zig-out/bin/boris \
  --input dogfood/site/content \
  --theme dogfood/site/theme \
  --layout-rule default id:index dogfood/site/theme/layouts/home.html \
  --layout-rule default 'glob:posts/*' dogfood/site/theme/layouts/post.html \
  --layout-rule default role:trunk dogfood/site/theme/layouts/section.html \
  --html-dir dogfood/out \
  --quiet

echo $?   # expect 0
open dogfood/out/index.html   # or any static file server
```

Full archive: omit `--limit` (or pass a high number). Re-run overwrites
generated Markdown under `dogfood/site/content/posts/` and re-copies media
into the theme assets tree.

## Intended site shape

```text
dogfood/site/
  content/
    index.md
    posts.md              # trunk
    posts/*.md            # satellites (one per IG post)
    about.md              # stub for non-IG sources
  theme/
    layouts/{home,section,post,main}.html
    footer.html
    assets/css/site.css
    assets/media/...      # copied from the dump (local only)
dogfood/out/              # boris HTML output
```

## Later sources

When the **list** and other exports land in `SUPPORT/`, extend import helpers
or hand-author trunks/satellites under `dogfood/site/content/`. Keep product
`content/` clean unless something is intentionally public sample material.

## Product gaps this dogfood is meant to surface

- Body images vs theme-owned `assets/` (relative paths at scale)
- Large Trunk/Satellite graphs (hundreds of posts)
- Blog-like layout selection (`--layout-rule`)
- Migration tooling that is not part of the default CLI

Record findings in STATUS / roadmap when they become release-relevant; do not
quietly invent product features inside `dogfood/`.
