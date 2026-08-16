### Fixed

- Standard.site login and session reuse now fail closed on four reachable
  mistakes: handle login requires the DID-document `alsoKnownAs` backlink,
  empty app-password input is a usage error rather than a fake PDS denial,
  a corrupt session file is no longer treated as “try the other credential,”
  and `getRecord` treats HTTP 404 as a missing record. See the
  [sessions contract](/docs/contracts/atproto-sessions.md) and issues
  [#547](https://github.com/drawmeanelephant/boris/issues/547),
  [#548](https://github.com/drawmeanelephant/boris/issues/548),
  [#549](https://github.com/drawmeanelephant/boris/issues/549), and
  [#550](https://github.com/drawmeanelephant/boris/issues/550).
