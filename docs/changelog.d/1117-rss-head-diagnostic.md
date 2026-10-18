### Fixed

- Profile RSS refusals and `InvalidHead` diagnostics now name the fix: the
  feed refusal points at the single-target enabled-`head` rider, an enabled
  head missing `base_url` reports `missing required field "base_url" in
  targets[N].head`, and the [publication-profile contract](/docs/contracts/publication-profile.md)
  cross-links `rss` to [head-metadata.md](/docs/contracts/head-metadata.md).
