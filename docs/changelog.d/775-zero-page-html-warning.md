# Zero-page HTML builds now warn

## Changed

- An HTML target whose content root scans to zero pages still publishes
  successfully (proof/search/theme assets, exit 0), but the compiler now prints
  a stderr warning naming the input root — including under `--quiet` — so an
  empty or mistyped `--input` can no longer masquerade as a populated site.
  `--timings` counters were verified honest for such runs (all zeros means no
  page work happened; [#775](https://github.com/drawmeanelephant/boris/issues/775));
  behavior is pinned in [the contract](/docs/contracts/html-output.md).
