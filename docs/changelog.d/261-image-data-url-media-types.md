### Security

- An inline `data:` image destination must now declare a real image media type.
  [`src/content_asset.zig`](/src/content_asset.zig) accepted any `data:` prefix
  as passthrough, so `data:text/html;base64,…` — a document, in an image slot —
  reached `dist/` unexamined. Only `image/png`, `image/jpeg`, `image/gif`,
  `image/webp` and `image/avif` pass; `image/svg+xml` is excluded because an
  inline SVG is a script-bearing document rather than a picture. Anything else
  fails the build with `EASSET` and a message naming the accepted types
  ([contract](/docs/contracts/content-local-assets.md)).
