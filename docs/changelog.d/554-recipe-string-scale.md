### Added

- Boris now classifies Cooklang amount strings as empty, scalable, or fixed
  and scales only the scalable ones as exact rationals
  ([#554](https://github.com/drawmeanelephant/boris/issues/554),
  [the Cooklang contract](/docs/contracts/cooklang-compatibility.md)).
  Source `.cook` files and `graph.json` are unchanged. A CLI that prints the
  scaled view is a later slice.
