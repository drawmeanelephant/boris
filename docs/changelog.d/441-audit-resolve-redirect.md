### Fixed

- `boris-github-pages-audit` now follows redirects correctly.
  `resolveRedirect` viewed the scratch buffer **past** the copied `Location`
  bytes, so the first redirect any audit observed resolved to a corrupt URL
  (uninitialized memory) and was rejected by the location policy even when
  the target was inside the declared location — e.g. the canonical
  no-trailing-slash → trailing-slash 301 on a GitHub Pages base URL, which
  failed the `rss` check for any feed whose channel link is the site root
  ([#441](https://github.com/drawmeanelephant/boris/issues/441)). The
  function also leaked its 16 KiB scratch buffer on every call. Regression
  tests cover the absolute and relative `Location` forms, and the observer's
  fixture suite now runs in CI.
