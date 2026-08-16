# Standard.site live-smoke evidence

Recorded result of an opt-in `boris standard-site smoke` run against a
dedicated bsky.social test identity, authenticated through the app-password
path. This is observational evidence, not a CI gate and not a certification
of any PDS.

| Field | Value |
|---|---|
| Artifact | [`bsky.social.json`](bsky.social.json) |
| Date | 2026-08-16 |
| Handle | `tbuddy23.bsky.social` |
| DID | `did:plc:fqf5y5yyddraj7pywme4al2i` |
| PDS | `https://morel.us-east.host.bsky.network` |
| Auth | stored `boris-app-password-v1` session (no OAuth scope) |
| Namespace | `boris-live-20260816c` |
| Verdict | `passed` |

The JSON contains identity facts, AT-URIs, CIDs, and phase outcomes only. It
contains no app password, access JWT, refresh JWT, or DPoP material.

Cleanup deleted both created rkeys. Re-running the same `--namespace` is
therefore allowed; a collision would mean a leftover record from an
interrupted run.

Indexer observation is non-normative and was `lagged` (AppView had not
ingested the document before cleanup). That does not affect the verdict.

See [`atproto-live-smoke.md`](../../atproto-live-smoke.md).
