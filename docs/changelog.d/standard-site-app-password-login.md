### Added

- Added the opt-in app-password credential path for Standard.site:
  `boris standard-site login --app-password (--did DID | --handle HANDLE)`
  resolves the identity, discloses the broad write access it grants, reads the
  app password from stdin (never argv, environment, profile, logs, or
  evidence), authenticates with `com.atproto.server.createSession`, and
  persists a `boris-app-password-v1` session under the same `0600`,
  atomically-replaced store as OAuth sessions. `standard-site publish` and
  `standard-site smoke` reuse a stored app-password session through the Bearer
  XRPC path and refresh it with the same rotate-or-die rule; OAuth remains the
  primary path and never falls back to a credential. See the
  [app-password RFC](/docs/contracts/atproto-app-password.md) and the
  [sessions contract](/docs/contracts/atproto-sessions.md).
