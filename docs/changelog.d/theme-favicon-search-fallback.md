### Fixed

- The default `boris` theme now ships an SVG favicon linked from every page
  (browsers no longer request a missing `/favicon.ico`), and its no-JavaScript
  search form submits to a themed landing page that explains the fallback
  instead of a missing `_boris/search/` route. Links:
  [the rendered-search contract](/docs/contracts/rendered-search.md),
  [the templating-and-themes contract](/docs/contracts/templating-and-themes.md),
  [#1180](https://github.com/drawmeanelephant/boris/issues/1180).
