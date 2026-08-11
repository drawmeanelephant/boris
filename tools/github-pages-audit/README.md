# Boris GitHub Pages deployment observer

`boris-github-pages-audit` is a standalone, opt-in observer. It consumes a
normalized publication plan, the exact committed target-local artifact
inventory, and the `page_url` returned by `deploy-pages`; it writes ordinary
deployment evidence and never changes the compiler's checks, claims,
limitations, Touch Atlas, Proof Pack, or public site tree.

Build and run the focused tests with:

```bash
zig build --build-file tools/github-pages-audit/build.zig test
zig build --build-file tools/github-pages-audit/build.zig
```

The default bounds are visible in the evidence and can be tightened with the
CLI flags: 256 requests, 8 MiB decoded response bodies, three redirect hops,
10 seconds per request, and 256 parsed URLs per projection or HTML page.
Redirects are restricted to the normalized GitHub Pages location. The observer
sends no cookies, authorization, or user-provided headers.

The files under `fixtures/` are local input fixtures. A local HTTP server may
serve them for manual CLI smoke tests; focused product tests do not contact the
public internet or use wall-clock timestamps.
