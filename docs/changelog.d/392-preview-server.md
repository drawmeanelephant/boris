## 392: local preview server (`watch --serve`)

`boris watch --serve [--port N]` serves the built HTML tree over loopback HTTP
on `127.0.0.1` (default port 8090, `--port 0` for an ephemeral port) and
reloads the browser after each successful rebuild. The server reuses the
existing watch coordinator — same debounced rebuild cycle, same artifacts,
diagnostics, and exit codes. `/` serves the built output statically
(`index.html` for the root), `/__boris/` is a helper page (site iframe +
EventSource) that auto-reloads after rebuilds, and `/__boris/events` is an SSE
stream carrying `event: reload` with a generation counter. The helper page and
SSE stream are server-generated responses only — the output directory on disk
is never modified. Loopback-only, static serving only (no HMR or script
injection), and multi-target builds serve the first canonical-order target.
Documented in `docs/contracts/cli.md`.
