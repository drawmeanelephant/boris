### Added

- Added additive [theme metadata hooks](/docs/contracts/templating-and-themes.md)
  (#1007): a repeatable, attribute-safe `{{page-status}}` token (e.g.
  `<body data-status="{{page-status}}">`, empty string when `status` is unset),
  a once-only `{{tags}}` slot emitting `<ul class="page-tags"><li>…</li></ul>`
  from closed `tags` frontmatter, and a once-only `{{parent}}` slot emitting a
  resolved direct-parent `<nav class="page-parent">` title/link from the frozen
  graph. The frozen `{{metadata}}` `<dl>` shape, raw parent id, and absent-marker
  output are unchanged; `ul.page-tags` and the Strict `div.page-parent` are
  excluded from [rendered search](/docs/contracts/rendered-search.md) as
  compiler chrome.
