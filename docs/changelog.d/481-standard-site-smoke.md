### Added

- Added the opt-in live interoperability smoke `boris standard-site smoke
  --did DID`, a manual, bounded gate that proves discovery, OAuth, XRPC writes,
  readback, verification surfaces, and cleanup against a real test identity.
  Every created record uses a unique `boris-smoke-<…>` namespace, is read back
  and verified before success is claimed, and cleanup deletes only the two
  rkeys the run created. The run emits a deterministic, secret-free
  `boris-live-smoke-result` artifact recording the exact server identity and
  specification baseline; indexer observation is reported but never gates the
  result. The live path is CLI-only and excluded from `zig build test` and all
  default CI paths. See the
  [live smoke contract](/docs/contracts/atproto-live-smoke.md).
