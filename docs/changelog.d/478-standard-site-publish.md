### Added

- Added the explicit one-shot publish command `boris standard-site publish
  --profile PATH`, composing the merged identity discovery and OAuth
  authorization with the Standard.site projection, verification surfaces, and
  reconciliation: resolve the configured DID, verify the DID document's PDS
  against the profile-bound PDS before the browser opens, authorize once
  in-memory, reconcile per-record with zero writes for unchanged state, and
  emit intended-vs-observed evidence to `--out` or stdout. `--plan` validates
  a committed plan byte-for-byte before any network mutation, `--prune` is the
  explicit prune authority, and `--source-commit` records the source revision.
  Exit codes 4–8 classify denial, timeout, compatibility, partial-publication,
  and verification failures; no secret ever appears in output or evidence. See
  the [standard-site](/docs/contracts/standard-site.md) and
  [reconciliation](/docs/contracts/standard-site-reconciliation.md)
  contracts.
