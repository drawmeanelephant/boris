### Fixed

- OAuth XRPC now sends `Authorization: DPoP <access_token>` and a separate
  `DPoP` proof header (RFC 9449). The native adapter admits GET 3 / POST 4
  headers for that shape. See the
  [OAuth contract](/docs/contracts/atproto-oauth.md) and
  [#536](https://github.com/drawmeanelephant/boris/issues/536).
