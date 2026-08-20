### Fixed

- The [archive-layout audit fixture](/docs/contracts/fixtures/archive-layout-audit/README.md)
  no longer overflows the page horizontally at phone widths: pages containing a
  `<table>` rendered up to 145 px wider than a 375 px viewport because the
  theme's `table { min-width: 32rem }` forced the table past its container and
  the `overflow-x: auto` sat on the table element itself. The horizontal
  overflow now lives on the table's parent (`article { overflow-x: auto }`), so
  the table keeps its readable minimum width and scrolls internally while the
  page stays fixed — confirmed by the real-browser pass recorded in
  [BROWSER-REVIEW.md](/docs/contracts/fixtures/archive-layout-audit/BROWSER-REVIEW.md)
  at 375 / 768 / 1440 px, with `test/archive-layout-audit.sh` still green.
