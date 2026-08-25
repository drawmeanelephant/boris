# GitHub Pages audit fixtures

The observer's fixture matrix is intentionally local and deterministic; it
does not call a public site. The cases in `src/audit.zig` cover the required
publication shapes and failure boundaries:

- project-site, root-site, and custom-domain location identities;
- unavailable root response;
- expected page returning 404;
- declared asset returning 404;
- redirect to the wrong origin or an escaped base path;
- canonical, sitemap, RSS, search, and `llms.txt` location disagreements;
- missing search-referenced pages;
- matching and mismatching committed body digests;
- response-body bound exhaustion;
- redirect-limit and timeout/incomplete transport behavior;
- deterministic request-budget truncation; and
- optional projections omitted from a plan.

The matrix exercises the same result vocabulary used by the wire observer:
`passed`, `failed`, `incomplete`, and `not-applicable`. The `project-site` and
`local-root` directories contain minimal plan/inventory pairs for deterministic
CLI smoke tests. A local HTTP server can serve the named cases when exercising
the network path manually; the product tests do not require public-network
access or wall-clock time.
