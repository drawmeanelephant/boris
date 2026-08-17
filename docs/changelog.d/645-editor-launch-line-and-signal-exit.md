<!--
Filename: 645-editor-launch-line-and-signal-exit.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Added

- `boris-editor` now documents and pins its subprocess contract: exactly one
  `BORIS_EDITOR_URL=http://127.0.0.1:<port>/#token=<32 hex chars>` line on
  stderr after bind, `--port 0` (default) reporting the bound port, the token
  in the URL fragment (or the `x-boris-editor-token` header for API calls),
  and an unchanged loopback/token/`Host`/`Origin`/CSP posture. `SIGINT` and
  `SIGTERM` now stop accepting, close the listener, and exit `0` — the same
  shutdown contract as `boris watch` — so embedders treat an uncaught-signal
  termination as cancel rather than crash. Pinned by the editor host test and
  documented in the [editor README](/editor/README.md).
