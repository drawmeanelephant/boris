# Real-site-shaped theme fixture

This fixture models a small documentation website rather than a compiler
unit-test edge case:

```text
content/index.md                       site home (Trunk)
content/guides.md                      guide landing page (Trunk)
content/guides/getting-started.md     guide page (Satellite)
content/reference.md                   API landing page (Trunk)
content/reference/configuration.md     API page (Satellite)
experimental-theme/layouts/main.html  all proposed slots
experimental-theme/footer.html         theme-owned footer fragment
experimental-theme/assets/css/docs.css static stylesheet
```

The content uses only the current closed frontmatter grammar and the existing
one-level Trunk/Satellite graph. The experimental theme is intentionally plain
CSS; it is a shape fixture for asset ownership and page-relative URLs, not a
DaisyUI implementation. F9.1 accepts `metadata`, `footer`, and `asset-url`
when the layout path is under a theme root (`…/layouts/main.html`).
`--theme experimental-theme` is sugar for that layout path.

Design acceptance expectations:

- `index.html` links to `assets/css/docs.css`.
- `guides/getting-started.html` links to `../assets/css/docs.css`.
- Each page contains its graph nav/breadcrumb, page-local TOC, metadata,
  content, and footer in the order declared by the layout.
- A second target can use a different theme without reading or overwriting
  the first target's assets or cache.
- The copied CSS bytes are exactly the theme input bytes.
- Full rebuild and incremental no-op produce **byte-identical** HTML pages and
  managed assets (cache manifest under `.boris-cache/` may be present only on
  incremental runs).
- Removing or renaming a theme asset removes the prior file from the target's
  published `assets/` (F9.2 orphan scrub).
