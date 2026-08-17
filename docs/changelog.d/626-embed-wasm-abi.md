### Added

- A `wasm32-wasi` [`compileBundle` ABI](/docs/contracts/embedding.md)
  exports files-in / diagnostics-and-IR-out through pointer/length
  handles. Hosts trap unused WASI imports. See
  [#611](https://github.com/drawmeanelephant/boris/issues/611).
