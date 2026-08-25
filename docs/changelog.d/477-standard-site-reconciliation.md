### Added

- Added Standard.site publish reconciliation: precondition verification of the
  session DID, PDS, collections, rkeys, and plan digest; per-record
  create/update/unchanged/failed/orphan classification with compare-and-swap,
  confirming reads for ambiguous writes, and explicit prune authority; plus a
  deterministic intended-vs-observed evidence artifact. See the
  [reconciliation contract](/docs/contracts/standard-site-reconciliation.md).
