### Fixed

- The native AT Protocol HTTPS adapter now admits the closed JSON/Bearer
  request shapes used by `standard-site login --app-password` and XRPC
  record calls, instead of rejecting them as `UnexpectedRequest` before a
  socket opened. Live `deleteRecord` accepts the lexicon `commitMeta`
  object, and live-smoke readback tolerates extra remote keys such as a
  PDS-injected `$type`. OAuth form+DPoP POSTs and discovery GETs are
  unchanged. See the [app-password RFC](/docs/contracts/atproto-app-password.md)
  and the [live smoke contract](/docs/contracts/atproto-live-smoke.md).
