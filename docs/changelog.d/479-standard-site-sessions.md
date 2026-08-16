### Added

- Added persistent Standard.site sessions: `boris standard-site login`
  authorizes a DID in the browser and persists the DPoP-bound session under a
  user-scoped, `0600`, atomically-replaced store; `boris standard-site
  sessions` lists stored DIDs; `boris standard-site logout` securely erases one
  session. `standard-site publish` now reuses a stored session and refreshes it
  in place (rotate-or-die, fail-closed after an ambiguous timeout) instead of
  re-opening the browser every run, and re-verifies the session's DID, PDS, and
  authorization server against fresh discovery before any write. Exit code 9
  classifies session-layer failures. See the
  [sessions contract](/docs/contracts/atproto-sessions.md) and the
  [diagnostics contract](/docs/contracts/diagnostics.md).
