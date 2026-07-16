# Instagram HTML dump → Boris Markdown (dogfood helper)

**Not product.** Offline Python helper for private real-site dogfood. Boris
does not depend on this package; it is never linked from `build.zig`.

Parses Meta’s HTML export (`your_instagram_activity/content/posts_*.html`),
writes Trunk/Satellite Markdown, and copies post media into a theme
`assets/media/` tree for local `{{asset-url}}`-adjacent relative links.

See [`docs/DOGFOOD.md`](../../docs/DOGFOOD.md).

```bash
python3 tools/dogfood-instagram-import/import_posts.py --help
```
