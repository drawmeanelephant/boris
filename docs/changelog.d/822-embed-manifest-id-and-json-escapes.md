### Fixed

- The Wasm embed result manifest now emits the contract-required `id` field on
  every diagnostic (string or null) and escapes raw C0 control bytes in JSON
  strings, so host-supplied file names containing control characters can no
  longer produce a manifest that fails `JSON.parse`. Links:
  [the diagnostics contract](/docs/contracts/diagnostics.md),
  [the embedding contract](/docs/contracts/embedding.md),
  [#822](https://github.com/drawmeanelephant/boris/issues/822),
  [#823](https://github.com/drawmeanelephant/boris/issues/823).
