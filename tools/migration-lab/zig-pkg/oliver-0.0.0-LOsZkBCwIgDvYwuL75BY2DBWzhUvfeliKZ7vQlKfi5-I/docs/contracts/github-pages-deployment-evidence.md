# GitHub Pages deployment evidence (schema v1)

**Status:** normative post-deploy observation contract for the optional
`boris-github-pages-audit` workflow step.

This format is deliberately separate from both the target-local publication
evidence and the public Pages artifact. It records what a bounded HTTP observer
saw after `actions/deploy-pages` returned a `page_url`; it does not change the
target-local checks, claims, limitations, Touch Atlas, Proof Pack, or public
payload.

## Producer and input boundary

The standalone Zig tool under `tools/github-pages-audit/` consumes:

- the normalized `boris-publication-plan` declaration;
- the exact target-local `boris-publication-artifacts` inventory and its file
  digest;
- the `page_url` output from the successful Pages deployment step;
- explicit workflow/source identity values when GitHub exposes them; and
- explicit audit bounds and timestamp.

It does not infer a repository path, domain, target, artifact list, or
deployment identity from a repository name or URL. Missing deployment IDs and
artifact IDs are recorded as `null`, not guessed.

## Result vocabulary

The root audit result and every check/observation use the closed vocabulary:

| Result | Meaning |
|---|---|
| `passed` | The bounded check completed and all of its observations passed. |
| `failed` | A response, location policy, byte comparison, or bounded parser check found a contradiction. |
| `incomplete` | The check could not complete within a declared request/body/redirect/URL bound or because transport data was unavailable. |
| `not-applicable` | The selected plan/inventory did not declare that projection or observation. |

`failed` and `incomplete` are never collapsed into a successful deployment
claim. A failed or incomplete audit still writes this report so the workflow
can upload actionable evidence.

## Location and request policy

Before the first request, `page_url` must match the normalized plan origin and
base path. A legitimate trailing slash is normalized for identity, while the
raw URL is retained in the root observation so a Pages root redirect remains
visible. Every redirect must be HTTP(S), contain no user information or
fragment, remain inside the declared origin/base path, and stay below the
redirect bound. Filesystem, `javascript:`, protocol-relative, credentialed,
and cross-origin redirect targets are rejected.

The observer sends `Accept-Encoding: identity`, never sends cookies,
authorization, or user-provided headers, and compares decoded response bytes
when the standard library reports a supported transfer encoding. It records
stable response metadata useful for diagnosis (`Content-Type`, cache control,
ETag, last-modified, content encoding, and content length), but headers are not
artifact identity. A status code, route alias, or CDN header never substitutes
for the committed SHA-256 and byte count.

The default bounds are 256 total HTTP requests (including redirects), 8 MiB
per decoded response body, 3 redirects per URL, a 10-second per-request
timeout, and 256 parsed URLs per projection or HTML page. All are explicit in
the report and can be tightened by the CLI/workflow. Inventory records are
visited in their canonical bytewise order; truncation is deterministic and
produces `incomplete` evidence.

## Checks

The observer always checks the deployment location precondition and the root
route. For each committed inventory record within the request bound it checks
reachability and compares status/body digest/byte count. HTML pages receive a
bounded same-location URL and canonical/public metadata pass. Selected
projection checks are:

- sitemap `<loc>` URLs remain inside the declared location;
- rendered-search `documents[].path` values are valid target-relative HTML
  paths and are bounded;
- RSS links, when an inventory record exists, remain inside the declared
  location; and
- absolute links in `llms.txt`, when an inventory record exists, agree with
  the declared location.

The observer does not claim universal browser reachability, all CDN cache
variants, all possible redirects, or future deployment stability. Those
limits are emitted as explicit `limitations` strings.

## Evidence shape

The machine-readable schema is
[`github-pages-deployment-evidence-1.schema.json`](https://github.com/drawmeanelephant/oliver/blob/main/docs/contracts/schemas/github-pages-deployment-evidence-1.schema.json).
The fixed root format is:

```json
{
  "format": "boris-github-pages-deployment-evidence",
  "schema_version": 1,
  "identity": {},
  "deployment": {},
  "binding": {
    "plan": {"path": "publication-plan.json", "sha256": "..."},
    "inventory": {"path": "proof/artifacts.json", "sha256": "..."}
  },
  "audit": {
    "audited_at": "2026-08-11T00:00:00Z",
    "result": "passed",
    "requests": 1,
    "completed_requests": 1,
    "truncated": false,
    "bounds": {},
    "checks": [],
    "observations": []
  },
  "limitations": []
}
```

The deployment object records `provider: "github-pages"` separately from the
target-local inventory name (`public` in the official workflow), so the
platform identity and artifact-target identity cannot be confused.

Object and array order is fixed by the Zig renderer. The report is an ordinary
retained workflow artifact and must never be copied into the public Pages
tree.
