### Changed

- `boris init` (the default `--type docs`) now writes the catalog
  [`boris`](/themes/boris/README.md) theme's full file set, as every other
  archetype writes its theme
  ([#1063](https://github.com/drawmeanelephant/boris/issues/1063),
  [#1046](https://github.com/drawmeanelephant/boris/issues/1046)). The
  private two-file starter theme it used to write had no `{{relations}}`,
  `{{backlinks}}`, `{{children}}`, or `{{metadata}}`, so the starter's index
  promised a semantic relation the theme could not show. It had also
  drifted from the catalog theme's fixes: slot adoption, the accessibility
  floor, the [#1049](https://github.com/drawmeanelephant/boris/issues/1049)
  visual pass, and the search-title marker. The relation now
  renders on both of its pages, the index lists its guides, and tags
  appear in the page header. Search works as before: the catalog layout
  ships the same browser search client. The cost is that `init --type
  docs` no longer writes the historical starter bytes, and the sidebar,
  `<title>` suffix, and footer say "Boris" until you edit the theme copy.
  See [the CLI contract](/docs/contracts/cli.md#init-deterministic-starter-scaffold-with-self-verification)
  and [the init theme matrix](/docs/init-theme-matrix.md).
