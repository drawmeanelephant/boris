### Added

- `boris init --type archive` writes a long-lived archive under `archive`:
  four tagged entries joined by `relates_to` and `supersedes` relations, so
  entry pages render `{{relations}}` and the derived `{{backlinks}}`; one
  `status: archived` record; and a hand-kept `topics` index by tag.
  `layout_rules` send `id:index` to the theme's `archive.html`
  ([#1059](https://github.com/drawmeanelephant/boris/issues/1059),
  [the CLI contract](/docs/contracts/cli.md#init-deterministic-starter-scaffold-with-self-verification)).
- `boris init --type dashboard` writes a project-status board under
  `engineering`: three projects, one per `status:` value, each showing a
  visible status label, with the status-to-project-state mapping
  (`published` = active, `draft` = proposed, `archived` = retired)
  documented on the board, `depends_on` / `supersedes` relations, and
  status-history tables. `layout_rules` send `id:index` to `home.html`
  ([#1062](https://github.com/drawmeanelephant/boris/issues/1062)).
- `boris init --type photo-gallery` writes an image gallery under the new
  `gallery` theme: a cover page and two albums, each page carrying small
  self-made PNG plates in its own `{stem}.assets/` folder inside
  `<figure>` captions, with `layout_rules` sending `id:index` to the
  album-grid `home.html`
  ([#1061](https://github.com/drawmeanelephant/boris/issues/1061),
  [content-local assets](/docs/contracts/content-local-assets.md)).
- The `boris init --type newsletter` profile now enables `head` and
  declares `rss`, so the first build writes a three-item `dist/feed.xml`
  and an autodiscovery link in every non-draft page head; a `status:
  draft` issue stays out of the feed and sitemap
  ([#1060](https://github.com/drawmeanelephant/boris/issues/1060),
  [head metadata](/docs/contracts/head-metadata.md#bounded-rss-rider-and-execution-boundary)).
- Every `boris init` starter now writes its theme's full catalog file set,
  including the `ACCESSIBILITY.md` that the `cards`, `service`,
  `reference`, `minimal`, `corporate`, and `showcase` READMEs link to
  ([#1046](https://github.com/drawmeanelephant/boris/issues/1046)).
