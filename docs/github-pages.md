# GitHub Pages publication

Boris includes an official GitHub Actions workflow at
`.github/workflows/github-pages.yml`. It builds the repository’s documentation
with the native Boris binary, resolves the Pages location through
`actions/configure-pages`, validates that location in a Boris publication
profile, and deploys only the verified public site tree.

## Enable the target

In the repository’s **Settings → Pages**, choose **GitHub Actions** as the
source. The workflow runs for pushes to `main` and can also be started with
**Run workflow**. The workflow uses the supported Pages action sequence:

1. `actions/checkout@v6`
2. `actions/configure-pages@v5`
3. `actions/upload-pages-artifact@v4`
4. `actions/deploy-pages@v4`

The workflow references immutable action commits with the released major
version in a comment. The Zig setup action is likewise pinned to the reviewed
`v2.2.1` commit.

It grants `contents: read` and `pages: read` to the build job. The deployment
job alone receives `pages: write` and `id-token: write`. Build and deployment
concurrency is serialized so an older run cannot cancel a newer deployment
halfway through.

## Location model

GitHub supplies three related values to the workflow: `base_url`, `origin`, and
`base_path`. Boris records them in the temporary profile used by
`boris plan --profile` and rejects contradictions before the site build:

| Pages shape | Example `base_url` | `origin` | `base_path` |
|---|---|---|---|
| Project site | `https://owner.github.io/boris` | `https://owner.github.io` | `/boris` |
| User/org root site | `https://owner.github.io` | `https://owner.github.io` | empty |
| Custom domain | `https://docs.example.com` | `https://docs.example.com` | empty |

The current declaration slice does not invent a CNAME or probe the network.
If a custom domain is configured with a non-empty path, or if `base_url` does
not equal `origin + base_path`, the profile fails closed. The normalized
identity is also available in the [publication profile](contracts/publication-profile.md)
and [publication plan](contracts/publication-plan.md) contracts.

The build step consumes that normalized plan identity directly:

```text
boris --target public=dist --sitemap \
  --pages-base-url https://owner.github.io/boris \
  --pages-origin https://owner.github.io \
  --pages-base-path /boris \
  --site-url https://owner.github.io/boris
```

The compiler audits rendered root-relative/public metadata URLs before target
replacement and binds sitemap URLs to the same identity. `EPUBLICATIONLOCATION`
is an actionable publication failure. Root and custom-domain builds pass an
explicit empty `--pages-base-path`. The check is against the local generated
artifact; this workflow still makes no post-deploy HTTP claim.

## Public artifact and retained evidence

The workflow creates two deliberately different uploads:

- The Pages artifact is copied from the exact `committed` records in
  `dist/_boris/proof/artifacts.json`. The copier checks every byte count and
  SHA-256, requires `index.html`, rejects symlinks and hard links, enforces the
  supported 1 GiB Pages artifact limit, and excludes `_boris/proof` reports.
- The retained evidence artifact contains the normalized plan, the target-local
  proof reports, and `github-pages-evidence.json`. That binding records the
  source commit, Boris/Apex pins, workflow identity, inventory digest, public
  file count/bytes, and the exact public-tree manifest digest.

The build summary reports the target, resolved URL/path, public payload size,
inventory binding, compiler finding count, and the explicit limitation that
deployment verification and a post-deploy HTTP audit are not claimed by this
workflow. A successful `deploy-pages` job means GitHub accepted the Pages
artifact for deployment; it is not a Boris claim that every URL projection or
browser request was audited.

## Optional post-deploy audit

The manual **Run workflow** form has an `audit_deployment` boolean, disabled by
default. When enabled, the deploy job downloads the exact retained plan and
target-local inventory from the build job, builds the standalone
`boris-github-pages-audit` Zig tool, and passes it the successful
`deploy-pages` `page_url`. Push-triggered runs keep the audit disabled unless a
future workflow-level control explicitly opts in.

The observer writes and uploads
`boris-github-pages-deployment-evidence-${{ github.run_id }}` as a separate
ordinary artifact. It is never copied into `public-site`, `_boris/proof`, or
the Pages artifact. The deployment summary distinguishes the build artifact,
deployment acceptance, and optional post-deploy audit. The audit step uses
`continue-on-error` so a failed or incomplete observation still reaches the
upload step; the JSON report carries the actionable result and limitations.

The default observer bounds are 256 HTTP requests including redirects, 8 MiB
per decoded response, three redirects per URL, a 10-second per-request
timeout, and 256 parsed URLs per projection/page. It sends no credentials or
cookies, accepts only HTTP(S) deployment URLs inside the normalized Pages
location, and records body digests separately from cache/ETag metadata. See
the [deployment evidence contract](contracts/github-pages-deployment-evidence.md)
for the result vocabulary, evidence binding, and coverage limits.

For GitHub’s workflow requirements and action behavior, see the
[custom workflows for GitHub Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages),
[`configure-pages`](https://github.com/actions/configure-pages),
[`upload-pages-artifact`](https://github.com/actions/upload-pages-artifact), and
[`deploy-pages`](https://github.com/actions/deploy-pages) documentation.
