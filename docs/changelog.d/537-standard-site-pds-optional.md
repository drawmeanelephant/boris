### Fixed

- Standard.site publish no longer requires profile `pds`. Omit it to bind
  to the PDS discovered from the DID document; if you set it, it must match
  that origin after parse. See the
  [Standard.site contract](/docs/contracts/standard-site.md) and
  [#537](https://github.com/drawmeanelephant/boris/issues/537).
